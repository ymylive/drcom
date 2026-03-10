#include "configparse.h"
#include <ctype.h>
#include <stdio.h>
#include <stdlib.h>
#include <string.h>
#include "debug.h"

int verbose_flag = 0;
int logging_flag = 0;
int eapol_flag = 0;
int eternal_flag = 0;
char *log_path;
char mode[10];
char bind_ip[20];
struct config drcom_config;

static int read_d_config(char *buf);
static int read_p_config(char *buf);
static char *trim_in_place(char *value);
static void strip_matching_quotes(char *value);
static int parse_key_value(char *buf, char **key, char **value);
static int copy_checked(char *dest, size_t dest_size, const char *value, const char *field_name);
static int equals_ignore_case(const char *left, const char *right);
static int parse_hex_byte_string(const char *value, unsigned char *result);
static int parse_two_byte_string(const char *value, unsigned char result[2]);
static int parse_mac_string(const char *value, unsigned char result[6]);
static int parse_bool_string(const char *value, int *result);

static char *trim_in_place(char *value) {
    char *end;

    if (value == NULL) {
        return NULL;
    }

    while (*value != '\0' && isspace((unsigned char)*value)) {
        value++;
    }

    if (*value == '\0') {
        return value;
    }

    end = value + strlen(value) - 1;
    while (end >= value && isspace((unsigned char)*end)) {
        *end = '\0';
        end--;
    }

    return value;
}

static void strip_matching_quotes(char *value) {
    size_t length;

    if (value == NULL) {
        return;
    }

    length = strlen(value);
    if (length < 2) {
        return;
    }

    if ((value[0] == '\'' && value[length - 1] == '\'') ||
        (value[0] == '"' && value[length - 1] == '"')) {
        memmove(value, value + 1, length - 2);
        value[length - 2] = '\0';
    }
}

static int parse_key_value(char *buf, char **key, char **value) {
    char *line;
    char *separator;

    line = trim_in_place(buf);
    if (line == NULL || *line == '\0' || *line == '#') {
        return 1;
    }

    separator = strchr(line, '=');
    if (separator == NULL) {
        return -1;
    }

    *separator = '\0';
    *key = trim_in_place(line);
    *value = trim_in_place(separator + 1);

    if (*key == NULL || **key == '\0') {
        return -1;
    }

    if (*value == NULL) {
        return -1;
    }

    strip_matching_quotes(*value);
    *value = trim_in_place(*value);
    return 0;
}

static int copy_checked(char *dest, size_t dest_size, const char *value, const char *field_name) {
    int written;

    if (dest == NULL || dest_size == 0 || value == NULL) {
        fprintf(stderr, "Invalid %s value.\n", field_name);
        return 1;
    }

    written = snprintf(dest, dest_size, "%s", value);
    if (written < 0 || (size_t)written >= dest_size) {
        fprintf(stderr, "%s is too long.\n", field_name);
        return 1;
    }

    return 0;
}

static int equals_ignore_case(const char *left, const char *right) {
    if (left == NULL || right == NULL) {
        return 0;
    }

    while (*left != '\0' && *right != '\0') {
        if (tolower((unsigned char)*left) != tolower((unsigned char)*right)) {
            return 0;
        }
        left++;
        right++;
    }

    return *left == '\0' && *right == '\0';
}

static int collect_hex_digits(const char *value, char *digits, size_t digits_size, size_t expected_digits) {
    size_t count = 0;

    if (value == NULL || digits == NULL || digits_size <= expected_digits) {
        return 1;
    }

    while (*value != '\0') {
        if (isxdigit((unsigned char)*value)) {
            if (count >= expected_digits) {
                return 1;
            }
            digits[count++] = *value;
        }
        value++;
    }

    digits[count] = '\0';
    return count == expected_digits ? 0 : 1;
}

static int parse_hex_byte_string(const char *value, unsigned char *result) {
    char digits[3];
    unsigned int parsed;

    if (result == NULL || collect_hex_digits(value, digits, sizeof(digits), 2) != 0) {
        return 1;
    }

    if (sscanf(digits, "%2x", &parsed) != 1) {
        return 1;
    }

    *result = (unsigned char)parsed;
    return 0;
}

static int parse_two_byte_string(const char *value, unsigned char result[2]) {
    char digits[5];
    unsigned int first;
    unsigned int second;

    if (result == NULL || collect_hex_digits(value, digits, sizeof(digits), 4) != 0) {
        return 1;
    }

    if (sscanf(digits, "%2x%2x", &first, &second) != 2) {
        return 1;
    }

    result[0] = (unsigned char)first;
    result[1] = (unsigned char)second;
    return 0;
}

static int parse_mac_string(const char *value, unsigned char result[6]) {
    char digits[13];
    unsigned int parsed[6];

    if (result == NULL || collect_hex_digits(value, digits, sizeof(digits), 12) != 0) {
        return 1;
    }

    if (sscanf(digits, "%2x%2x%2x%2x%2x%2x",
               &parsed[0], &parsed[1], &parsed[2],
               &parsed[3], &parsed[4], &parsed[5]) != 6) {
        return 1;
    }

    for (int i = 0; i < 6; i++) {
        result[i] = (unsigned char)parsed[i];
    }

    return 0;
}

static int parse_bool_string(const char *value, int *result) {
    if (result == NULL) {
        return 1;
    }

    if (equals_ignore_case(value, "True")) {
        *result = 1;
        return 0;
    }

    if (strcmp(value, "1") == 0) {
        *result = 1;
        return 0;
    }

    if (equals_ignore_case(value, "False")) {
        *result = 0;
        return 0;
    }

    if (strcmp(value, "0") == 0) {
        *result = 0;
        return 0;
    }

    return 1;
}

int config_parse(char *filepath) {
    FILE *ptr_file;
    char buf[256];
    int line_number = 0;
    int result;

    ptr_file = fopen(filepath, "r");
    if (!ptr_file) {
        fprintf(stderr, "Failed to read config file: %s\n", filepath);
        return 1;
    }

    memset(&drcom_config, 0, sizeof(drcom_config));

    while (fgets(buf, sizeof(buf), ptr_file)) {
        line_number++;

        if (strcmp(mode, "dhcp") == 0) {
            result = read_d_config(buf);
        } else if (strcmp(mode, "pppoe") == 0) {
            result = read_p_config(buf);
        } else {
            fprintf(stderr, "Unknown mode: %s\n", mode);
            fclose(ptr_file);
            return 1;
        }

        if (result != 0) {
            fprintf(stderr, "Failed to parse config line %d.\n", line_number);
            fclose(ptr_file);
            return 1;
        }
    }

    if (verbose_flag) {
        printf("\n\n");
    }

    fclose(ptr_file);
    return 0;
}

static void debug_log_string(const char *field_name, const char *value, int redact) {
#ifdef DEBUG
    if (redact) {
        printf("[PARSER_DEBUG]%s=<redacted>\n", field_name);
    } else {
        printf("[PARSER_DEBUG]%s=%s\n", field_name, value != NULL ? value : "");
    }
#else
    (void)field_name;
    (void)value;
    (void)redact;
#endif
}

static int read_d_config(char *buf) {
    char *key = NULL;
    char *value = NULL;
    unsigned char parsed_byte;
    unsigned char parsed_two_bytes[2];
    unsigned char parsed_mac[6];
    int parsed_bool;
    int key_value_state;

    if (verbose_flag) {
        printf("%s", buf);
    }

    key_value_state = parse_key_value(buf, &key, &value);
    if (key_value_state > 0) {
        return 0;
    }
    if (key_value_state < 0) {
        return 1;
    }

    if (strcmp(key, "server") == 0) {
        if (copy_checked(drcom_config.server, sizeof(drcom_config.server), value, "server") != 0) {
            return 1;
        }
        debug_log_string("server", drcom_config.server, 0);
    } else if (strcmp(key, "username") == 0) {
        if (copy_checked(drcom_config.username, sizeof(drcom_config.username), value, "username") != 0) {
            return 1;
        }
        debug_log_string("username", drcom_config.username, 0);
    } else if (strcmp(key, "password") == 0) {
        if (copy_checked(drcom_config.password, sizeof(drcom_config.password), value, "password") != 0) {
            return 1;
        }
        debug_log_string("password", drcom_config.password, 1);
    } else if (strcmp(key, "CONTROLCHECKSTATUS") == 0) {
        if (parse_hex_byte_string(value, &parsed_byte) != 0) {
            return 1;
        }
        drcom_config.CONTROLCHECKSTATUS = parsed_byte;
        DEBUG_PRINT(("[PARSER_DEBUG]CONTROLCHECKSTATUS=0x%02x\n", drcom_config.CONTROLCHECKSTATUS));
    } else if (strcmp(key, "ADAPTERNUM") == 0) {
        if (parse_hex_byte_string(value, &parsed_byte) != 0) {
            return 1;
        }
        drcom_config.ADAPTERNUM = parsed_byte;
        DEBUG_PRINT(("[PARSER_DEBUG]ADAPTERNUM=0x%02x\n", drcom_config.ADAPTERNUM));
    } else if (strcmp(key, "host_ip") == 0) {
        if (copy_checked(drcom_config.host_ip, sizeof(drcom_config.host_ip), value, "host_ip") != 0) {
            return 1;
        }
        debug_log_string("host_ip", drcom_config.host_ip, 0);
    } else if (strcmp(key, "IPDOG") == 0) {
        if (parse_hex_byte_string(value, &parsed_byte) != 0) {
            return 1;
        }
        drcom_config.IPDOG = parsed_byte;
        DEBUG_PRINT(("[PARSER_DEBUG]IPDOG=0x%02x\n", drcom_config.IPDOG));
    } else if (strcmp(key, "host_name") == 0) {
        if (copy_checked(drcom_config.host_name, sizeof(drcom_config.host_name), value, "host_name") != 0) {
            return 1;
        }
        debug_log_string("host_name", drcom_config.host_name, 0);
    } else if (strcmp(key, "PRIMARY_DNS") == 0) {
        if (copy_checked(drcom_config.PRIMARY_DNS, sizeof(drcom_config.PRIMARY_DNS), value, "PRIMARY_DNS") != 0) {
            return 1;
        }
        debug_log_string("PRIMARY_DNS", drcom_config.PRIMARY_DNS, 0);
    } else if (strcmp(key, "SECONDARY_DNS") == 0) {
        debug_log_string("SECONDARY_DNS", value, 0);
    } else if (strcmp(key, "dhcp_server") == 0) {
        if (copy_checked(drcom_config.dhcp_server, sizeof(drcom_config.dhcp_server), value, "dhcp_server") != 0) {
            return 1;
        }
        debug_log_string("dhcp_server", drcom_config.dhcp_server, 0);
    } else if (strcmp(key, "AUTH_VERSION") == 0) {
        if (parse_two_byte_string(value, parsed_two_bytes) != 0) {
            return 1;
        }
        memcpy(drcom_config.AUTH_VERSION, parsed_two_bytes, sizeof(drcom_config.AUTH_VERSION));
        DEBUG_PRINT(("[PARSER_DEBUG]AUTH_VERSION=0x%02x%02x\n", drcom_config.AUTH_VERSION[0], drcom_config.AUTH_VERSION[1]));
    } else if (strcmp(key, "mac") == 0) {
        if (parse_mac_string(value, parsed_mac) != 0) {
            return 1;
        }
        memcpy(drcom_config.mac, parsed_mac, sizeof(drcom_config.mac));
#ifdef DEBUG
        printf("[PARSER_DEBUG]mac=0x");
        for (int i = 0; i < 6; i++) {
            printf("%02x", drcom_config.mac[i]);
        }
        printf("\n");
#endif
    } else if (strcmp(key, "host_os") == 0) {
        if (copy_checked(drcom_config.host_os, sizeof(drcom_config.host_os), value, "host_os") != 0) {
            return 1;
        }
        debug_log_string("host_os", drcom_config.host_os, 0);
    } else if (strcmp(key, "KEEP_ALIVE_VERSION") == 0) {
        if (parse_two_byte_string(value, parsed_two_bytes) != 0) {
            return 1;
        }
        memcpy(drcom_config.KEEP_ALIVE_VERSION, parsed_two_bytes, sizeof(drcom_config.KEEP_ALIVE_VERSION));
        DEBUG_PRINT(("[PARSER_DEBUG]KEEP_ALIVE_VERSION=0x%02x%02x\n", drcom_config.KEEP_ALIVE_VERSION[0], drcom_config.KEEP_ALIVE_VERSION[1]));
    } else if (strcmp(key, "ror_version") == 0) {
        if (parse_bool_string(value, &parsed_bool) != 0) {
            return 1;
        }
        drcom_config.ror_version = parsed_bool;
        DEBUG_PRINT(("[PARSER_DEBUG]ror_version=%d\n", drcom_config.ror_version));
    } else if (strcmp(key, "keepalive1_mod") == 0) {
        if (parse_bool_string(value, &parsed_bool) != 0) {
            return 1;
        }
        drcom_config.keepalive1_mod = parsed_bool;
        DEBUG_PRINT(("[PARSER_DEBUG]keepalive1_mod=%d\n", drcom_config.keepalive1_mod));
    } else if (strcmp(key, "bind_ip") == 0) {
        if (copy_checked(bind_ip, sizeof(bind_ip), value, "bind_ip") != 0) {
            return 1;
        }
        debug_log_string("bind_ip", bind_ip, 0);
    } else if (strcmp(key, "log") == 0) {
        char *copy = strdup(value);
        if (copy == NULL) {
            fprintf(stderr, "Out of memory while copying log path.\n");
            return 1;
        }
        free(log_path);
        log_path = copy;
        logging_flag = 1;
        debug_log_string("log", log_path, 0);
    } else if (strcmp(key, "eternal") == 0) {
        if (parse_bool_string(value, &parsed_bool) != 0) {
            return 1;
        }
        eternal_flag = parsed_bool;
        DEBUG_PRINT(("[PARSER_DEBUG]eternal=%d\n", eternal_flag));
    } else {
        return 1;
    }

    return 0;
}

static int read_p_config(char *buf) {
    char *key = NULL;
    char *value = NULL;
    unsigned char parsed_byte;
    int key_value_state;

    if (verbose_flag) {
        printf("%s", buf);
    }

    key_value_state = parse_key_value(buf, &key, &value);
    if (key_value_state > 0) {
        return 0;
    }
    if (key_value_state < 0) {
        return 1;
    }

    if (strcmp(key, "server") == 0) {
        if (copy_checked(drcom_config.server, sizeof(drcom_config.server), value, "server") != 0) {
            return 1;
        }
        debug_log_string("server", drcom_config.server, 0);
    } else if (strcmp(key, "pppoe_flag") == 0) {
        if (parse_hex_byte_string(value, &parsed_byte) != 0) {
            return 1;
        }
        drcom_config.pppoe_flag = parsed_byte;
        DEBUG_PRINT(("[PARSER_DEBUG]pppoe_flag=0x%02x\n", drcom_config.pppoe_flag));
    } else if (strcmp(key, "keep_alive2_flag") == 0) {
        if (parse_hex_byte_string(value, &parsed_byte) != 0) {
            return 1;
        }
        drcom_config.keep_alive2_flag = parsed_byte;
        DEBUG_PRINT(("[PARSER_DEBUG]keep_alive2_flag=0x%02x\n", drcom_config.keep_alive2_flag));
    } else {
        return 1;
    }

    return 0;
}
