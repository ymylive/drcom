module("luci.controller.drcom", package.seeall)

local CONF_PATH = "/etc/drcom.conf"
local INIT_PATH = "/etc/init.d/drcom"
local LOG_PATH = "/tmp/drcom.log"
local SERVICE_NAME = "drcom"
local BIND_PORT = "61440"
local PORT_STATE_PATH = "/tmp/drcom-port-state"
local SNAPSHOT_CACHE_TTL = 3
local snapshot_cache = { full = nil, created_at = 0 }
local i18n = require "luci.i18n"

local json = nil
local json_ok, json_lib = pcall(require, "luci.jsonc")
if json_ok then
	json = json_lib
else
	local legacy_ok, legacy_json = pcall(require, "luci.json")
	if legacy_ok then
		json = legacy_json
	end
end

local function translate(text)
	if i18n.load then
		i18n.load("drcom")
	elseif i18n.loadc then
		i18n.loadc("drcom")
	end

	return i18n.translate(text)
end

local function localized_message(key, text)
	return {
		key = key,
		text = translate(text)
	}
end

local function trim(value)
	if value == nil then
		return ""
	end

	return tostring(value):gsub("^%s+", ""):gsub("%s+$", "")
end

local function split_lines(text)
	local lines = {}
	local normalized = tostring(text or ""):gsub("\r\n?", "\n")
	if normalized == "" then
		return lines
	end
	if normalized:sub(-1) ~= "\n" then
		normalized = normalized .. "\n"
	end
	for line in normalized:gmatch("(.-)\n") do
		if not (line == "" and #lines > 0 and lines[#lines] == "") then
			table.insert(lines, line)
		end
	end
	return lines
end

local function count_keys(items)
	local total = 0
	local _
	for _ in pairs(items or {}) do
		total = total + 1
	end
	return total
end

local function shell_exec(command)
	local sys = require "luci.sys"
	return trim(sys.exec(command .. " 2>/dev/null"))
end

local function shell_quote(value)
	local escaped = trim(value):gsub("'", [['"'"']])
	return "'" .. escaped .. "'"
end

local function shell_ok(command)
	local sys = require "luci.sys"
	return sys.call(command .. " >/dev/null 2>&1") == 0
end

local function get_pid()
	return shell_exec("pidof " .. SERVICE_NAME .. " | awk '{print $1}'")
end

local function normalize_conf_value(value)
	local normalized = trim(value)
	normalized = normalized:gsub("^'(.*)'$", "%1")
	normalized = normalized:gsub('^"(.*)"$', "%1")
	return normalized
end

local function parse_config(text)
	local conf = {
		keys = {},
		raw_lines = 0,
		non_empty_lines = 0
	}
	local normalized = tostring(text or ""):gsub("\r\n?", "\n")

	if normalized == "" then
		return conf
	end
	if normalized:sub(-1) ~= "\n" then
		normalized = normalized .. "\n"
	end

	for line in normalized:gmatch("(.-)\n") do
		conf.raw_lines = conf.raw_lines + 1

		if line:match("%S") and not line:match("^%s*#") then
			conf.non_empty_lines = conf.non_empty_lines + 1
			local key, value = line:match("^%s*([%w_]+)%s*=%s*(.-)%s*$")
			if key then
				conf.keys[key] = normalize_conf_value(value)
			end
		end
	end

	return conf
end

local function validate_config(conf)
	local required_keys = {
		"server",
		"username",
		"password",
		"host_ip",
		"mac",
		"AUTH_VERSION",
		"KEEP_ALIVE_VERSION"
	}
	local missing_keys = {}
	local warnings = {}
	local function add_warning(key, text)
		table.insert(warnings, localized_message(key, text))
	end

	for _, key in ipairs(required_keys) do
		if trim(conf.keys[key]) == "" then
			table.insert(missing_keys, key)
		end
	end

	if conf.keys.server ~= nil and conf.keys.server ~= "" and not conf.keys.server:match("^%d+%.%d+%.%d+%.%d+$") then
		add_warning("config.warning.serverIpv4", "server should be an IPv4 address.")
	end

	if conf.keys.host_ip ~= nil and conf.keys.host_ip ~= "" and not conf.keys.host_ip:match("^%d+%.%d+%.%d+%.%d+$") then
		add_warning("config.warning.hostIpIpv4", "host_ip should be an IPv4 address.")
	end

	if conf.keys.mac ~= nil and conf.keys.mac ~= "" and not (
		conf.keys.mac:match("^0x[%x][%x][%x][%x][%x][%x][%x][%x][%x][%x][%x][%x]$") or
		conf.keys.mac:match("^[%x][%x]:[%x][%x]:[%x][%x]:[%x][%x]:[%x][%x]:[%x][%x]$")
	) then
		add_warning("config.warning.macFormat", "mac should use either 0xB025AA851014 or B0:25:AA:85:10:14.")
	end

	if conf.keys.ror_version ~= nil and conf.keys.ror_version ~= "" and conf.keys.ror_version ~= "True" and conf.keys.ror_version ~= "False" then
		add_warning("config.warning.rorVersion", "ror_version should be True or False.")
	end

	if conf.keys.keepalive1_mod == nil or conf.keys.keepalive1_mod == "" then
		add_warning("config.warning.keepalive1Mod", "keepalive1_mod is recommended to improve compatibility.")
	end

	if conf.non_empty_lines ~= 0 and count_keys(conf.keys) == 0 then
		add_warning("config.warning.unsupportedFormat", "Configuration uses an unsupported format; prefer dogcom-style key = 'value' lines.")
	end

	return {
		valid = #missing_keys == 0,
		missing_keys = missing_keys,
		warnings = warnings,
		parsed_keys = count_keys(conf.keys),
		non_empty_lines = conf.non_empty_lines,
		raw_lines = conf.raw_lines
	}
end

local function read_log_tail(limit)
	local fs = require "nixio.fs"
	limit = tonumber(limit) or 160

	if fs.access(LOG_PATH) then
		return {
			text = shell_exec("tail -n " .. limit .. " " .. LOG_PATH),
			source = LOG_PATH
		}
	end

	return {
		text = shell_exec("logread | grep -E 'drcom|dogcom|EAP|procd' | tail -n " .. limit),
		source = "logread"
	}
end

local function append_unique(items, seen, value)
	value = trim(value)
	if value == "" or seen[value] then
		return
	end

	seen[value] = true
	table.insert(items, value)
end

local function split_csv(value)
	local items = {}
	for item in tostring(value or ""):gmatch("([^,]+)") do
		table.insert(items, trim(item))
	end
	return items
end

local function get_port_usage(port)
	local output = shell_exec("(ss -lunp || netstat -lunp)")
	local lines = {}
	local pids = {}
	local owners = {}
	local seen_lines = {}
	local seen_pids = {}
	local seen_owners = {}
	local pattern = ":" .. tostring(port)

	for _, line in ipairs(split_lines(output)) do
		if line:find(pattern, 1, true) then
			append_unique(lines, seen_lines, line)
			for pid in line:gmatch("pid=(%d+)") do
				append_unique(pids, seen_pids, pid)
			end
			for pid, owner in line:gmatch("(%d+)/([%w%._%-]+)") do
				append_unique(pids, seen_pids, pid)
				append_unique(owners, seen_owners, owner)
			end
			for owner in line:gmatch('%("([^"]+)"') do
				append_unique(owners, seen_owners, owner)
			end
		end
	end

	return {
		in_use = #lines > 0,
		lines = lines,
		line = lines[1] or "",
		pids = pids,
		owners = owners
	}
end

local function read_state_file(path)
	local fs = require "nixio.fs"
	return parse_config(fs.readfile(path) or "")
end

local function first_ipv4_address(runtime)
	local entries = runtime and runtime["ipv4-address"]
	local first = entries and entries[1]
	if not first then
		return ""
	end
	return trim(first.address or "")
end

local function read_wan_runtime()
	local raw = shell_exec("ubus call network.interface.wan status")
	local data = nil
	local proto = trim(shell_exec("uci -q get network.wan.proto"))
	local device = ""
	local address = ""

	if raw ~= "" and json then
		if json.parse then
			data = json.parse(raw)
		elseif json.decode then
			data = json.decode(raw)
		end
	end

	if data then
		proto = trim(data.proto or proto)
		device = trim(data.l3_device or data.device or "")
		address = first_ipv4_address(data)
	end

	return {
		proto = proto,
		device = device,
		address = address
	}
end

local function detect_challenge(log_text)
	local send_line = ""
	local lines = split_lines(log_text)
	local index

	for index = #lines, 1, -1 do
		local line = trim(lines[index])
		if line ~= "" then
			if line:match("Login success") then
				return { code = "authenticated", status = translate("Authenticated"), line = line }
			elseif line:match("%[Challenge recv%]") then
				return { code = "received", status = translate("Received"), line = line }
			elseif line:match("Failed to recv data") then
				return { code = "timeout", status = translate("Timed out"), line = line }
			elseif line:match("Not server in range") then
				return { code = "unreachable", status = translate("Unreachable"), line = line }
			elseif line:match("%[Challenge sent%]") then
				send_line = line
				break
			end
		end
	end

	if send_line ~= "" then
		return { code = "waiting", status = translate("Waiting"), line = send_line }
	end

	return { code = "idle", status = translate("Idle"), line = "" }
end

local function build_network_state(conf, log_text, service_pid)
	local state = read_state_file(PORT_STATE_PATH)
	local wan_runtime = read_wan_runtime()
	local configured_server = trim(conf.keys.server)
	local configured_host_ip = trim(conf.keys.host_ip)
	local route_line = ""
	local route_source_ip = ""
	local route_interface = ""
	local port_usage = get_port_usage(BIND_PORT)
	local port_blocked = false
	local challenge = detect_challenge(log_text)
	local idx

	if configured_server ~= "" then
		route_line = shell_exec("ip route get " .. shell_quote(configured_server) .. " | head -n 1")
		route_source_ip = trim(route_line:match("src%s+(%d+%.%d+%.%d+%.%d+)") or "")
		route_interface = trim(route_line:match("dev%s+([%w%._%-]+)") or "")
	end

	if port_usage.in_use then
		for idx = 1, #port_usage.lines do
			local line = port_usage.lines[idx]
			local owned_by_service = false
			if service_pid ~= "" and line:match("pid=" .. service_pid) then
				owned_by_service = true
			elseif line:match(SERVICE_NAME) then
				owned_by_service = true
			end

			if not owned_by_service then
				port_blocked = true
				break
			end
		end
	end

	return {
		bind_port = BIND_PORT,
		auto_port_recovery = true,
		configured_server = configured_server,
		configured_host_ip = configured_host_ip,
		wan_proto = wan_runtime.proto,
		wan_device = wan_runtime.device,
		wan_address = wan_runtime.address,
		route_line = route_line,
		interface = route_interface,
		route_source_ip = route_source_ip,
		port_in_use = port_usage.in_use,
		port_blocked = port_blocked,
		port_mode = port_usage.in_use and (port_blocked and "blocked" or "listening") or "free",
		port_line = port_usage.line,
		port_lines = port_usage.lines,
		port_pids = port_usage.pids,
		port_owners = port_usage.owners,
		port_state = trim(state.keys.status),
		port_state_message = trim(state.keys.message),
		port_state_time = trim(state.keys.timestamp),
		recovery_status = trim(state.keys.status),
		recovery_message = trim(state.keys.message),
		recovery_time = trim(state.keys.timestamp),
		recovery_pids = split_csv(state.keys.pids),
		recovery_owners = split_csv(state.keys.owners),
		challenge_code = challenge.code,
		challenge_status = challenge.status,
		challenge_line = challenge.line
	}
end

local function append_issue(issues, seen, severity, title_key, title_text, line, hint_key, hint_text)
	local dedupe_key = title_key or title_text or ""
	if dedupe_key == "" or seen[dedupe_key] then
		return
	end

	seen[dedupe_key] = true
	table.insert(issues, {
		severity = severity,
		title_key = title_key,
		title = translate(title_text),
		line = trim(line),
		hint_key = hint_key,
		hint = translate(hint_text)
	})
end

local function extract_issues(log_text, config_state, running, network_state)
	local issues = {}
	local seen = {}
	local lines = split_lines(log_text)
	local index

	for index = #lines, 1, -1 do
		local line = lines[index]
		if line:match("Segmentation fault") then
			append_issue(issues, seen, "critical", "issue.programCrashed.title", "Program crashed", line, "issue.programCrashed.hint", "Check config format carefully, especially mac and boolean fields.")
		elseif line:match("Failed to bind socket") or line:match("Address in use") then
			append_issue(issues, seen, "warning", "issue.portOccupied.title", "Port 61440 is occupied", line, "issue.portOccupied.hint", "Stop duplicate drcom processes before starting a foreground session.")
		elseif line:match("Permission denied") then
			append_issue(issues, seen, "critical", "issue.permissionProblem.title", "Permission problem detected", line, "issue.permissionProblem.hint", "Verify executable permissions for init script, binary, and opkg scripts.")
		elseif line:match("Server forced this account offline") or line:match("Retrying in %d+ seconds") then
			append_issue(issues, seen, "warning", nil, "Server cooldown is active", line, nil, "The campus server temporarily blocks re-login after a forced logout. Wait for the reported cooldown before retrying.")
		elseif line:match("Password error") or line:match("Account and password not match") then
			append_issue(issues, seen, "critical", "issue.authFailed.title", "Authentication failed", line, "issue.authFailed.hint", "Confirm username and password from the campus account.")
		elseif line:match("No this user") then
			append_issue(issues, seen, "critical", "issue.userNotFound.title", "User does not exist", line, "issue.userNotFound.hint", "Check the username format exported from the official client.")
		elseif line:match("Not server in range") or line:match("Failed to recv data") then
			append_issue(issues, seen, "warning", "issue.serverNoResponse.title", "Server did not respond", line, "issue.serverNoResponse.hint", "Verify server, host_ip, upstream interface, and whether 802.1X is required.")
		elseif line:match("crash loop") then
			append_issue(issues, seen, "critical", "issue.crashLoop.title", "Service is crashing repeatedly", line, "issue.crashLoop.hint", "Run drcom in foreground and inspect the latest error before re-enabling respawn.")
		elseif line:match("Failed to keep in touch") then
			append_issue(issues, seen, "warning", "issue.keepaliveFailed.title", "Keepalive failed", line, "issue.keepaliveFailed.hint", "Login may have succeeded but keepalive packets are not being acknowledged.")
		elseif line:match("Login success") then
			append_issue(issues, seen, "info", "issue.loginSucceeded.title", "Login succeeded recently", line, "issue.loginSucceeded.hint", "If Internet still fails, continue checking route, DNS, and NAT status.")
		end

		if #issues >= 5 then
			break
		end
	end

	if not running then
		append_issue(issues, seen, "warning", "issue.serviceNotRunning.title", "Service is not running", "", "issue.serviceNotRunning.hint", "Use Start or Restart after fixing the reported configuration or runtime issue.")
	end

	if network_state then
		if network_state.port_blocked then
			append_issue(issues, seen, "warning", "issue.portStillOccupied.title", "Port 61440 is still occupied", network_state.port_line, "issue.portStillOccupied.hint", "The service now attempts automatic recovery before start, but another process still owns the socket.")
		end

		if network_state.recovery_status == "failed" or network_state.recovery_status == "busy" then
			append_issue(issues, seen, "warning", "issue.autoRecoveryFailed.title", "Automatic port recovery failed", network_state.recovery_message, "issue.autoRecoveryFailed.hint", "Inspect the listed PIDs and stop the conflicting process manually if needed.")
		elseif network_state.recovery_status == "recovered" then
			append_issue(issues, seen, "info", "issue.autoRecoverySucceeded.title", "Automatic port recovery succeeded", network_state.recovery_message, "issue.autoRecoverySucceeded.hint", "The service cleared stale listeners before binding port 61440.")
		end

		if network_state.configured_host_ip ~= "" and network_state.route_source_ip ~= "" and network_state.configured_host_ip ~= network_state.route_source_ip then
			append_issue(issues, seen, "warning", "issue.hostIpMismatch.title", "host_ip does not match the active route source", network_state.route_source_ip, "issue.hostIpMismatch.hint", "Update host_ip to the source address chosen by the current route, or pin the route/interface first.")
		end
	end

	if not config_state.valid then
		append_issue(issues, seen, "warning", "issue.configIncomplete.title", "Configuration is incomplete", table.concat(config_state.missing_keys, ", "), "issue.configIncomplete.hint", "Fill in the missing required keys before restarting the service.")
	end

	local idx
	for idx = 1, #config_state.warnings do
		append_issue(issues, seen, "info", "issue.configWarning.title", "Configuration warning", config_state.warnings[idx].text, "issue.configWarning.hint", "Review the config editor helper text for recommended formatting.")
		if #issues >= 5 then
			break
		end
	end

	return issues
end

local function write_json(payload)
	local http = require "luci.http"
	http.prepare_content("application/json")
	if json and json.stringify then
		http.write(json.stringify(payload))
	else
		http.write("{}")
	end
end

local function find_last_log_line(text)
	local lines = split_lines(text)
	local idx
	for idx = #lines, 1, -1 do
		local line = trim(lines[idx])
		if line ~= "" then
			return line
		end
	end
	return ""
end

local function clone_snapshot(snapshot, include_logs)
	local copy = {}
	local key
	for key, value in pairs(snapshot or {}) do
		if include_logs or key ~= "logs" then
			copy[key] = value
		end
	end
	return copy
end

local function invalidate_snapshot_cache()
	snapshot_cache.full = nil
	snapshot_cache.created_at = 0
end

local function get_request_token()
	local http = require "luci.http"
	return trim(http.formvalue("token"))
end

local function is_valid_request_token()
	local disp = require "luci.dispatcher"
	local expected = trim((disp.context and disp.context.authtoken) or "")
	if expected == "" then
		return true
	end
	return get_request_token() == expected
end

local function build_snapshot(include_logs, force_refresh)
	local fs = require "nixio.fs"
	local now = os.time()
	if not force_refresh and snapshot_cache.full and (now - snapshot_cache.created_at) < SNAPSHOT_CACHE_TTL then
		return clone_snapshot(snapshot_cache.full, include_logs)
	end

	local pid = get_pid()
	local running = pid ~= ""
	local enabled = shell_ok("test -L /etc/rc.d/S90drcom")
	local conf_text = fs.readfile(CONF_PATH) or ""
	local conf = parse_config(conf_text)
	local config_state = validate_config(conf)
	local log_state = read_log_tail(160)
	local network_state = build_network_state(conf, log_state.text, pid)
	local issues = extract_issues(log_state.text, config_state, running, network_state)

	local snapshot = {
		running = running,
		pid = pid,
		enabled = enabled,
		log_path = LOG_PATH,
		log_source = log_state.source,
		updated_at = os.date("%Y-%m-%d %H:%M:%S"),
		config = {
			valid = config_state.valid,
			missing_keys = config_state.missing_keys,
			warnings = config_state.warnings,
			parsed_keys = config_state.parsed_keys,
			non_empty_lines = config_state.non_empty_lines,
			raw_lines = config_state.raw_lines,
			server = trim(conf.keys.server),
			host_ip = trim(conf.keys.host_ip),
			mac = trim(conf.keys.mac),
			username = trim(conf.keys.username)
		},
		last_error = issues[1],
		last_log = find_last_log_line(log_state.text),
		issues = issues,
		errors = issues,
		config_path = CONF_PATH,
		network = network_state
	}

	snapshot.logs = log_state.text

	snapshot_cache.full = clone_snapshot(snapshot, true)
	snapshot_cache.created_at = now

	return clone_snapshot(snapshot_cache.full, include_logs)
end

local function run_service_action(action)
	local allowed = {
		start = true,
		stop = true,
		restart = true,
		enable = true,
		disable = true
	}

	if not allowed[action] then
		return false, localized_message("service.unsupportedAction", "Unsupported service action.")
	end

	if not shell_ok("test -x " .. INIT_PATH) then
		return false, localized_message("service.scriptMissing", "Service script is missing or not executable.")
	end

	if not shell_ok(INIT_PATH .. " " .. action) then
		return false, localized_message("service.commandFailed", "Service command failed.")
	end

	return true, localized_message("service.actionSubmitted", "Service action submitted.")
end

function index()
	local fs = require "nixio.fs"

	if fs.access(CONF_PATH) then
		local page = entry({"admin", "services", "drcom"}, call("render_form"), translate("DrCOM"), 10)
		page.i18n = "drcom"
		page.dependent = true

		entry({"admin", "services", "drcom", "status"}, call("status_json")).leaf = true
		entry({"admin", "services", "drcom", "logs"}, call("logs_json")).leaf = true
		entry({"admin", "services", "drcom", "service"}, call("service_action")).leaf = true
	end
end

function status_json()
	write_json(build_snapshot(false))
end

function logs_json()
	local snapshot = build_snapshot(true)
	write_json({
		logs = snapshot.logs or "",
		log_source = snapshot.log_source,
		updated_at = snapshot.updated_at,
		errors = snapshot.errors or {},
		last_error = snapshot.last_error
	})
end

function service_action()
	local http = require "luci.http"
	if http.getenv("REQUEST_METHOD") ~= "POST" then
		http.status(405, "Method Not Allowed")
		local message = localized_message("form.postRequired", "POST is required.")
		write_json({ ok = false, error = message.text, error_key = message.key })
		return
	end

	if not is_valid_request_token() then
		http.status(403, "Forbidden")
		local message = localized_message("form.requestTokenMismatch", "Request token mismatch.")
		write_json({ ok = false, error = message.text, error_key = message.key })
		return
	end

	local action = trim(http.formvalue("action"))
	local ok, message = run_service_action(action)
	invalidate_snapshot_cache()
	write_json({
		ok = ok,
		action = action,
		message = message.text,
		message_key = message.key,
		status = build_snapshot(false, true),
		error = ok and nil or message.text,
		error_key = ok and nil or message.key
	})
end

function render_form()
	local http = require "luci.http"
	local tpl = require "luci.template"
	local fs = require "nixio.fs"
	local sys = require "luci.sys"
	local disp = require "luci.dispatcher"
	local token = (disp.context and disp.context.authtoken) or ""
	local status_url = disp.build_url("admin", "services", "drcom", "status")
	local logs_url = disp.build_url("admin", "services", "drcom", "logs")
	local service_url = disp.build_url("admin", "services", "drcom", "service")

	local message
	local message_key
	local message_type = "success"
	local body = fs.readfile(CONF_PATH) or ""

	if http.getenv("REQUEST_METHOD") == "POST" then
		local action = trim(http.formvalue("service_action"))
		if not is_valid_request_token() then
			http.status(403, "Forbidden")
			local info = localized_message("form.requestTokenMismatch", "Request token mismatch.")
			message = info.text
			message_key = info.key
			message_type = "error"
		elseif action == "save_restart" then
			body = (http.formvalue("conf") or ""):gsub("\r\n?", "\n")
			fs.writefile(CONF_PATH, body)
			invalidate_snapshot_cache()
			if shell_ok(INIT_PATH .. " restart") then
				local info = localized_message("form.configSavedRestarting", "Configuration saved. Service restarting (check status and logs below).")
				message = info.text
				message_key = info.key
				message_type = "success"
			else
				local info = localized_message("form.configSavedRestartFailed", "Configuration saved, but restart failed. Review the status and logs panels below.")
				message = info.text
				message_key = info.key
				message_type = "error"
			end
		elseif action ~= "" then
			local ok, action_message = run_service_action(action)
			message = action_message.text
			message_key = action_message.key
			message_type = ok and "success" or "error"
			invalidate_snapshot_cache()
		end
	end

	local snapshot = build_snapshot(true, true)

	tpl.render("drcom/form", {
		token = token,
		conf = body,
		message = message,
		message_key = message_key,
		message_type = message_type,
		status = snapshot,
		logs = snapshot.logs or "",
		status_url = status_url,
		logs_url = logs_url,
		service_url = service_url,
		log_path = LOG_PATH,
		conf_path = CONF_PATH
	})
end
