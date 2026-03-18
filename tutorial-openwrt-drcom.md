# 用 OpenWrt 路由器完成 DrCOM 校园网认证：通用插件服务实战教程

很多校园网环境仍然使用 DrCOM 认证。对宿舍或实验室网络来说，直接在电脑上登录虽然简单，但一旦希望把认证交给 OpenWrt 路由器长期托管，就会遇到几个典型问题：

- 官方客户端只能跑在桌面系统上
- 路由器重启后需要重新认证
- 排障时很难同时看到配置、服务状态和日志
- 不同学校的接入要求不完全一致，容易被误以为只能做“某校专用”

这篇文章介绍一个更通用的方案：把 DrCOM 认证做成 OpenWrt 上的插件服务，让路由器自己完成登录、保活、日志记录和 LuCI 管理。

本文介绍的项目基于 `dogcom` C 实现，适合资源受限的 OpenWrt 设备长期运行，并且带有 LuCI 页面、配置校验和基础诊断能力。

## 一、这个项目能做什么

这个项目的定位不是“某个学校专用客户端”，而是一个适用于 OpenWrt 的通用 DrCOM 插件服务，主要提供：

- `drcom_openwrt` 二进制认证程序
- `/etc/init.d/drcom_openwrt` 服务管理脚本
- `/etc/drcom.conf` 配置文件
- LuCI 管理页面
- 日志查看与基础诊断
- 启动前自动处理 UDP `61440` 端口占用问题

也就是说，你不需要把认证放在电脑上常驻运行，而是可以直接让路由器接管。

## 二、适合哪些场景

如果你的网络满足下面任一情况，这种方式通常都值得尝试：

- 宿舍网络使用 DrCOM 认证
- 需要让全屋设备共享校园网出口
- 希望路由器重启后自动恢复认证
- 想把配置、日志、服务控制统一到 LuCI 页面里

需要注意的是，“通用”不代表“零配置差异”。不同学校的 DrCOM 环境可能在以下方面不同：

- 是否要求静态 IP
- 是否绑定 MAC
- DNS 和网关是否必须手动填写
- 是否先做 802.1X，再做 DrCOM
- `AUTH_VERSION` 和 `KEEP_ALIVE_VERSION` 是否需要特定值

所以正确的理解应该是：这个项目提供的是通用 OpenWrt 运行框架，而学校差异主要体现在配置项上。

## 三、项目结构速览

如果你准备自己维护或二次打包，目录结构可以先看一遍：

- `drcom/`：OpenWrt 包源码目录。为了兼容当前仓库结构，源码目录仍然叫 `drcom/`，但 Release 安装后的包名是 `drcom_openwrt`
- `drcom/src/`：认证程序源码
- `drcom/files/etc/drcom.conf`：默认配置模板
- `drcom/files/etc/init.d/drcom`：源码中的服务脚本模板，打包后会安装为 `/etc/init.d/drcom_openwrt`
- `drcom/files/usr/lib/lua/luci/controller/drcom.lua`：LuCI 控制器
- `drcom/files/usr/lib/lua/luci/view/drcom/form.htm`：LuCI 页面
- `scripts/build-openwrt-sdk-ipk.sh`：基于官方 SDK 打包单个 `ipk`
- `.github/workflows/build-ipk.yml`：GitHub Actions 自动构建流程

如果你只是使用成品包，其实只需要关心安装、配置和排障这三件事。

## 四、安装方式

### 方式 1：直接安装 Release 产物

如果仓库已经发布了对应架构的 `ipk`，这是最省事的方案。

在 OpenWrt 中上传后执行：

```sh
opkg install /tmp/drcom_openwrt_*.ipk --force-reinstall
chmod 600 /etc/drcom.conf
/etc/init.d/drcom_openwrt enable
/etc/init.d/drcom_openwrt restart
```

安装完成后，可以在 LuCI 中进入：

`服务 -> DrCOM`

如果路由器上之前装过旧包名 `jludrcom` 或 `drcom`，建议先移除旧包，再安装新的 `drcom_openwrt`。

### 方式 2：作为 OpenWrt feed 使用

这里同样有一个命名差异：

- Release 直接安装到路由器上的包名是 `drcom_openwrt`
- 仓库里的 OpenWrt 源码目录和 feed 目标当前仍然叫 `drcom`

所以如果你是在自己的 OpenWrt 固件源码里集成，下面这些命令仍然使用 `drcom`：

```sh
echo 'src-git ymylive_drcom https://github.com/ymylive/drcom.git' >> feeds.conf.default
./scripts/feeds update ymylive_drcom
./scripts/feeds install -p ymylive_drcom drcom
make menuconfig
```

然后在 `Network` 分类中选择源码包 `drcom` 进行编译；最终发布出来的安装包名仍是 `drcom_openwrt`。

### 方式 3：直接复制包目录到 OpenWrt/SDK

如果你本地已经有 OpenWrt SDK 或源码树，也可以直接把包目录复制进去：

```sh
make package/drcom/compile V=s
```

## 五、最关键的一步：先确认校园网接入方式

很多人调试 DrCOM 最大的问题，不是账号密码，而是上游网络参数本身没配对。

在不少校园网环境里，OpenWrt 的 `WAN` 口在做 DrCOM 认证之前，必须先配置成静态地址。常见要求包括：

- 指定 `IPv4 address`
- 指定掩码
- 指定网关
- 指定 DNS
- 指定绑定后的 MAC

如果你的学校要求这样做，正确顺序通常是：

1. 先把 `WAN` 改成静态地址
2. 填好学校分配或登记的 IP、网关、DNS、MAC
3. 确认路由器能到达认证服务器
4. 再启动 `drcom_openwrt`

例如先确认路由可达：

```sh
ip route get 10.100.61.3
```

如果这一步都不通，那么后面看到的 `Challenge` 重试、`Network unreachable`、无回包，大概率都只是结果，不是根因。

## 六、配置文件怎么写

默认配置文件路径：

```sh
/etc/drcom.conf
```

最小必填项通常包括：

- `server`
- `username`
- `password`
- `host_ip`
- `mac`
- `AUTH_VERSION`
- `KEEP_ALIVE_VERSION`

一份典型配置如下：

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

### 关于 MAC 的写法

如果你的 MAC 是：

```text
B0:25:AA:85:10:14
```

推荐写成：

```ini
mac=0xB025AA851014
```

当前解析器也兼容：

```ini
mac='B0:25:AA:85:10:14'
```

但推荐优先使用 `0x` 格式，兼容性更稳。

## 七、LuCI 页面能做什么

项目带有一个比较实用的 LuCI 页面，不只是“填配置然后点重启”这么简单。

页面里可以直接看到：

- 服务是否在运行
- 配置是否缺少关键项
- 最近错误摘要
- 网络状态
- 实时日志
- 诊断建议

这比单纯 SSH 上去翻日志要高效很多，尤其是在以下场景：

- 服务没起来，但你不确定是配置错误还是端口占用
- `Challenge` 阶段反复重试
- 认证成功后又很快掉线
- 路由器上已经有别的进程占用了 UDP `61440`

## 八、常用运维命令

### 启动、停止、重启服务

```sh
/etc/init.d/drcom_openwrt start
/etc/init.d/drcom_openwrt stop
/etc/init.d/drcom_openwrt restart
```

### 设置开机自启

```sh
/etc/init.d/drcom_openwrt enable
```

### 查看实时日志

```sh
tail -f /tmp/drcom.log
```

### 查看进程状态

```sh
ps w | grep [d]rcom_openwrt
```

### 查看系统日志中的相关记录

```sh
logread | grep -E 'drcom|dogcom|EAP'
```

## 九、推荐的排障流程

如果认证失败，不要上来就反复改密码。建议按这个顺序排查。

### 1. 先确认上游网络

看 `WAN` 是否真的按学校要求配好了：

- IP 是否正确
- 网关是否正确
- DNS 是否正确
- MAC 是否和绑定信息一致

### 2. 再确认配置文件格式

常见错误包括：

- 少写了 `AUTH_VERSION`
- 少写了 `KEEP_ALIVE_VERSION`
- `mac` 格式不对
- `True/False` 写法不对
- 字符串引号不规范

### 3. 检查端口是否被占用

DrCOM 常用 UDP `61440`。如果之前有旧进程残留，服务可能起不来。

项目已经在启动前做了自动处理，但你仍然可以手动检查：

```sh
ss -lunp | grep ':61440'
```

### 4. 前台运行观察首个错误

这是最有价值的一步：

```sh
/etc/init.d/drcom_openwrt stop
killall drcom_openwrt 2>/dev/null
/usr/bin/drcom_openwrt -m dhcp -c /etc/drcom.conf -e -l /tmp/drcom.log
```

这样可以直接看到第一条真实错误，而不是只看服务失败结果。

## 十、为什么这个方案适合长期使用

相比“在电脑上挂客户端”，OpenWrt 插件服务的优势非常明显：

- 路由器重启后可自动恢复
- 不依赖 PC 在线
- 资源占用低
- 更适合全屋设备共享
- 更容易集中管理和排障
- 便于持续集成和多架构打包

如果你自己维护固件，仓库里还提供了基于 OpenWrt 官方 SDK 的自动打包脚本和 GitHub Actions 工作流，可以直接产出多架构 `ipk`。

## 十一、总结

DrCOM 并不一定要绑死在 Windows 客户端上。只要学校网络允许、参数配置正确，完全可以把认证能力收敛到 OpenWrt 路由器里，变成一个可持续维护、可自动重启、可统一排障的服务。

这个项目的核心价值不在于“适配某一个学校”，而在于给 OpenWrt 提供了一个通用的 DrCOM 认证承载方式。学校差异通过配置解决，运行框架由路由器统一接管。

如果你正好也在折腾宿舍网络、实验室路由或者旁路由认证，这套方案会比传统桌面客户端更稳定，也更工程化。

---

如果你准备把这篇文章发到博客平台，可以再补一段你自己的实际使用环境，比如：

- 路由器型号
- OpenWrt 版本
- 校园网是否要求静态 IP
- 最终使用的 `AUTH_VERSION` / `KEEP_ALIVE_VERSION`

这样文章会更有说服力，也更方便后续搜索流量沉淀。
