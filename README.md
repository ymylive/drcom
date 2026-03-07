# jludrcom

吉林大学校园网 DrCOM 客户端 OpenWrt 包，基于 `dogcom` C 实现，额外集成 LuCI 控制面板。

这个仓库的目标不是只存一个现成 `ipk`，而是提供一套可复用、可自动编译、可持续维护的 OpenWrt 包源码：
- 路由器端运行的 `jludrcom` 二进制
- LuCI 控制面板
- 默认配置模板
- `procd` 服务脚本
- GitHub Actions 自动编译多架构 `ipk`

## 功能特性

- 基于 C 实现的 DrCOM 客户端，适合 OpenWrt 路由器长期运行
- LuCI 控制面板，支持配置编辑、当前状态、日志查看、错误诊断
- `Save & Restart` 正常工作，不再触发 LuCI `_` 空值报错
- 启动前自动检测 UDP `61440` 端口占用，并尝试清理冲突进程
- 实时展示 challenge 状态、路由源地址、自动恢复结果
- 默认样例配置已经补齐常见关键字段，减少首次启动踩坑

## 目录结构

- `jludrcom/`：OpenWrt 包目录
- `jludrcom/src/`：内置的 `dogcom` C 源码副本，用于跨架构编译
- `jludrcom/files/`：安装到路由器上的配置、服务脚本和 LuCI 页面
- `.github/workflows/build-ipk.yml`：GitHub Actions 自动构建工作流

## 安装方式

### 1. 直接安装工作流产物

在 GitHub Actions 或 Release 中下载对应架构的 `ipk`，上传到 OpenWrt / iStoreOS 后安装：

```sh
opkg install /tmp/jludrcom_*.ipk
chmod 600 /etc/drcom.conf
/etc/init.d/jludrcom enable
/etc/init.d/jludrcom restart
```

安装完成后进入：

`LuCI -> 服务 -> DrCOM for JLU`

### 2. 作为 OpenWrt Feed 使用

在你的 OpenWrt / SDK 根目录里添加自定义 feed：

```sh
echo 'src-git ymylive_drcom https://github.com/ymylive/drcom.git' >> feeds.conf.default
./scripts/feeds update ymylive_drcom
./scripts/feeds install -p ymylive_drcom jludrcom
make menuconfig
```

然后在 `Network` 分类里选择 `jludrcom`，再执行编译。

### 3. 本地包目录方式

如果你只是临时测试，也可以把 `jludrcom/` 整个目录复制到 OpenWrt 源码树的 `package/` 下，然后执行：

```sh
make package/jludrcom/compile V=s
```

## 配置说明

默认配置文件安装到：

`/etc/drcom.conf`

推荐格式示例：

```ini
username=your_username
password=your_password
server=10.10.10.10
PRIMARY_DNS=10.10.10.10
SECONDARY_DNS=8.8.8.8
host_name=OpenWrt
host_os=Windows 10
mac=0x001122334455
host_ip=0.0.0.0
dhcp_server=0.0.0.0
CONTROLCHECKSTATUS=\x20
ADAPTERNUM=\x05
IPDOG=\x01
AUTH_VERSION=\x2c\x00
KEEP_ALIVE_VERSION=\xdc\x02
ror_version=False
keepalive1_mod=True
```

### MAC 地址格式

如果你抓包得到的是：

`B0:25:AA:85:10:14`

则在配置里应写成：

`0xB025AA851014`

不要写成带空格、带连字符或普通十六进制整数，否则容易导致解析异常甚至运行时崩溃。

## 前台调试

遇到登录失败、端口占用或 challenge 超时，可以用下面这组命令调试：

```sh
/etc/init.d/jludrcom stop
killall jludrcom 2>/dev/null
ss -lunp | grep ':61440'
/usr/bin/jludrcom -m dhcp -c /etc/drcom.conf -e -l /tmp/jludrcom.log
```

看日志：

```sh
tail -f /tmp/jludrcom.log
```

看运行状态：

```sh
ps w | grep [j]ludrcom
logread | grep -E 'jludrcom|dogcom|EAP|drcom'
```

## LuCI 控制面板

当前页面已经扩展为控制面板，包含：
- 当前服务状态
- 配置健康度检查
- 最近错误与修复建议
- `Network Status` 网络诊断卡片
- 实时日志
- 自动刷新与手动服务控制

其中网络诊断会显示：
- 绑定端口是否被占用
- 当前路由和源 IP 是否与 `host_ip` 匹配
- challenge 是否收到响应
- 自动端口恢复是否成功

## GitHub Actions 自动构建

仓库内置 `.github/workflows/build-ipk.yml`：
- 对 `main` 分支提交自动构建
- 支持手动触发 `workflow_dispatch`
- 对 `v*` 标签自动生成 Release 并附带 `ipk`
- 按 OpenWrt 24.10 多架构矩阵编译

之所以固定到 OpenWrt `24.10.x`，是因为从 OpenWrt `25.12` 开始官方已切换到 `apk` 包管理；本仓库当前目标是稳定产出 `ipk`。

如果后续你要切换到新的 OpenWrt 系列，只需要改 workflow 里的 `OPENWRT_RELEASE`。

## 上游来源与许可证

- C 客户端源码基于上游 `dogcom`
- 仓库根目录 `LICENSE` 保留上游 AGPL 许可证文本
- OpenWrt / LuCI 适配与控制面板改造在此仓库继续维护

## 后续建议

- 建议把常用学校参数做成一个可选配置向导
- 建议后续补一个“配置格式自动转换”功能，例如把 `B0:25:AA:85:10:14` 自动转成 `0xB025AA851014`
- 如果你准备长期维护，可以继续加上 Issue 模板、Release 模板和变更日志