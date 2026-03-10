# jludrcom

吉林大学校园网 DrCOM 客户端 OpenWrt 包源码仓库，基于 `dogcom` C 实现，并集成 LuCI 控制面板。

这个仓库的目标不是只存一个现成 `ipk`，而是提供一套可以持续维护、自动构建、直接发布的 OpenWrt 包源码：

- `jludrcom` 二进制
- LuCI 控制面板
- 默认配置模板
- `procd` 服务脚本
- GitHub Actions 多架构自动构建与 Release 发布

## 功能

- 基于 C 实现，适合路由器长期运行
- LuCI 控制面板，支持配置编辑、状态查看、日志查看、错误诊断
- `Save & Restart` 正常工作
- 启动前自动检测并清理 UDP `61440` 端口占用
- 支持旧版 dogcom 风格配置语法
- 增加服务端强制下线冷却识别，避免把 `0x15` 误判成单纯客户端版本错误

## 目录结构

- `jludrcom/`：OpenWrt 包目录
- `jludrcom/src/`：内置 `dogcom` C 源码
- `jludrcom/files/`：安装到路由器上的配置、服务脚本、LuCI 页面
- `scripts/generate-openwrt-sdk-matrix.py`：从 OpenWrt 官方 release 自动发现 SDK，并按 `pkgarch` 去重
- `scripts/build-openwrt-sdk-ipk.sh`：使用官方 SDK toolchain + `scripts/ipkg-build` 手工打包单个 `ipk`
- `.github/workflows/build-ipk.yml`：GitHub Actions 自动构建与发布流程

## 安装

### 直接安装 Release 产物

在 GitHub Release 中下载对应架构的 `ipk`，上传到 OpenWrt / iStoreOS：

```sh
opkg install /tmp/jludrcom_*.ipk --force-reinstall
chmod 600 /etc/drcom.conf
/etc/init.d/jludrcom enable
/etc/init.d/jludrcom restart
```

安装后进入：

`LuCI -> 服务 -> DrCOM for JLU`

### 先在 OpenWrt 里把 WAN 配成静态地址

对于吉林大学当前这类接入场景，应该先在 OpenWrt 接口页面里把 `WAN` 配置为**静态地址**，再启动 `jludrcom` 认证。

LuCI 路径：

`网络 -> 接口 -> WAN -> 编辑 -> 协议: 静态地址`

至少要保证以下几项填写正确：

- `IPv4 address`：填写学校分配给你的固定地址，并与 `/etc/drcom.conf` 里的 `host_ip` 保持一致
- `IPv4 netmask`：填写学校网络对应掩码
- `IPv4 gateway`：填写学校网络网关
- `Use custom DNS servers`：填写学校要求的 DNS，例如 `10.10.10.10`
- `MAC`：如果学校做了绑定，WAN 口 MAC 也要改成绑定后的地址

推荐顺序：

1. 先把 `WAN` 切换成 `静态地址`
2. 保存并应用接口配置
3. 确认能够路由到认证服务器，例如：

```sh
ip route get 10.100.61.3
```

4. 再启动 `jludrcom`

如果这里仍然提示 `Network unreachable`、`到认证服务器没有路由` 或 `Challenge` 一直重试，优先排查的不是账号密码，而是 `WAN` 的静态地址、网关、DNS 和 MAC 是否与学校侧登记信息一致。

### 作为 OpenWrt feed 使用

```sh
echo 'src-git ymylive_drcom https://github.com/ymylive/drcom.git' >> feeds.conf.default
./scripts/feeds update ymylive_drcom
./scripts/feeds install -p ymylive_drcom jludrcom
make menuconfig
```

然后在 `Network` 分类里选择 `jludrcom`。

### 复制包目录到 OpenWrt / SDK

如果你在本地 OpenWrt 源码树里直接测试，也可以把 `jludrcom/` 复制到 `package/` 下：

```sh
make package/jludrcom/compile V=s
```

## 配置

配置文件路径：

`/etc/drcom.conf`

最小必填项：

- `server`
- `username`
- `password`
- `host_ip`
- `mac`
- `AUTH_VERSION`
- `KEEP_ALIVE_VERSION`

推荐格式：

```ini
username='your_username'
password='your_password'
server='10.100.61.3'
PRIMARY_DNS='10.10.10.10'
SECONDARY_DNS='8.8.8.8'
host_name='OpenWrt'
host_os='Windows 10'
mac=0xB025AA851014
host_ip='172.18.0.100'
dhcp_server='0.0.0.0'
CONTROLCHECKSTATUS='\x20'
ADAPTERNUM='\x05'
IPDOG='\x01'
AUTH_VERSION='\x2c\x00'
KEEP_ALIVE_VERSION='\xdc\x02'
ror_version=False
keepalive1_mod=True
```

### MAC 写法

如果你的物理 MAC 是：

`B0:25:AA:85:10:14`

推荐在配置里写：

`0xB025AA851014`

当前解析器也接受：

`B0:25:AA:85:10:14`

但不要写带空格、带连字符或普通整数格式。

### 学校网络注意事项

对于 JLU 这类场景，优先按下面方式处理：

- 在 OpenWrt 接口页面把 `WAN` 配置成 `静态地址`
- `host_ip` 必须与 `WAN` 的静态地址一致
- 网关 / DNS / MAC 必须与学校侧实际要求一致
- 然后再进行 DrCOM 认证

如果 `Challenge` 阶段一直重试但没有回应，优先检查 WAN 接入方式。

## 前台调试

```sh
/etc/init.d/jludrcom stop
killall jludrcom 2>/dev/null
ss -lunp | grep ':61440'
/usr/bin/jludrcom -m dhcp -c /etc/drcom.conf -e -l /tmp/jludrcom.log
```

查看日志：

```sh
tail -f /tmp/jludrcom.log
```

查看运行状态：

```sh
ps w | grep [j]ludrcom
logread | grep -E 'jludrcom|dogcom|EAP|drcom'
```

## GitHub Actions 工作流

当前工作流不再使用 `gh-action-sdk + make package/.../compile` 路线，而是改为和本地已验证结果一致的手工打包路线：

1. `verify`：校验 Lua、内联 JS、配置解析器测试
2. `plan-matrix`：从 OpenWrt 官方 release 页面自动发现 target / subtarget，并从 `packages/Packages.gz` 提取 `Architecture`，按 `pkgarch` 去重
3. `build`：对每个唯一 `pkgarch` 使用官方 SDK toolchain 交叉编译，并调用 SDK 自带 `scripts/ipkg-build`
4. `release`：在标签构建时直接发布多个 `.ipk` 和 `.sha256`

### 发布产物规则

- 每个架构单独生成一个 `ipk`
- 每个 `ipk` 对应一个 `.sha256`
- Release **直接上传这些文件**
- **不会**再额外打一个 zip / tar.gz 包

产物命名格式：

- `jludrcom_<version>-<release>_<pkgarch>.ipk`
- `jludrcom_<version>-<release>_<pkgarch>.ipk.sha256`

## 支持架构

本地已经验证：

- `aarch64_generic`（R2S / `rockchip/armv8`）

GitHub Actions 会从 OpenWrt 官方 `24.10.5` release 自动发现并去重所有可用 `pkgarch`，因此最终 Release 会直接包含该版本官方 SDK 能构建出的多架构 `ipk`。

如果后续要切换 OpenWrt 版本，只需要改 `.github/workflows/build-ipk.yml` 里的 `OPENWRT_RELEASE`。

## 本地复现单架构打包

如果你已经有一个官方 SDK，也可以直接复用仓库脚本本地打包：

```sh
bash scripts/build-openwrt-sdk-ipk.sh \
  --package-root ./jludrcom \
  --release 24.10.5 \
  --target rockchip \
  --subtarget armv8 \
  --sdk-root /path/to/openwrt-sdk-24.10.5-rockchip-armv8_gcc-13.3.0_musl.Linux-x86_64 \
  --output-dir ./dist/aarch64_generic
```

## 许可证

- C 客户端源码基于上游 `dogcom`
- 仓库保留上游 AGPL 许可证文本
- OpenWrt / LuCI 适配和控制面板改造在本仓库继续维护
