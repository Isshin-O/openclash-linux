# openclash-linux：在普通 Linux 上原样运行 OpenClash

把 OpenWrt **24.10** 的网页栈（ubus / uci / rpcd / uhttpd / ucode / LuCI）和 OpenClash 后端要用的系统组件
（procd / opkg / fw4 / dnsmasq / busybox crond）从源码编译出来，装到普通 Linux（systemd）上，再用 opkg 装上游 luci-app-openclash。
上游的 sh/ruby/lua 后端和 LuCI 页面都不改；打开网址就是 OpenClash 运行状态页，只有 OpenClash 6 页 + 系统状态/系统日志/进程。

发布用 `release.sh` 在 Debian 11（glibc 2.31）chroot 里统一编译，Lua、ruby 和它们依赖的库全部自带，打成一个自解压安装包
`openclash-linux-<版本>-<arch>.run`。目标机只要求 systemd、glibc ≥ 2.31、x86-64 基础指令集（不用 SSE4.2/AVX），
外加几个各发行版都有的命令（见「依赖」）。已验证：Ubuntu 26.04（WSL，网络命名空间）、Fedora 44（systemd-nspawn 容器，firewalld 开启）、Debian 11（systemd-nspawn 容器，systemd 247）、飞牛 fnOS（实机，Debian 12 系，真实订阅 + 6 种运行模式）。

## 一键安装

```bash
curl -fsSL https://github.com/Isshin-O/openclash-linux/releases/latest/download/get.sh | sudo sh
```

装完按提示在浏览器打开 `http://<本机局域网 IP>/`，用 root 或执行 sudo 的那个账号、以它自己的系统密码登录，之后和路由器上的 OpenClash 一样用。
家里设备把网关和 DNS 指向这台机器就走代理。

- 安装参数接在 `sh -s --` 后面，例如 `... | sudo sh -s -- --listen 0.0.0.0:8080`（参数见「安装 / 卸载」）
- 国内直连 GitHub 不通时，给下载地址加代理前缀（两处都要加）：
  `curl -fsSL https://gh-proxy.com/https://github.com/Isshin-O/openclash-linux/releases/latest/download/get.sh | sudo OC_MIRROR=https://gh-proxy.com/ sh`
- 只下载、校验，不安装：`... | sh -s -- --download-only`（安装包存到当前目录，之后 `sudo sh openclash-linux-*.run`）
- 卸载：`sudo /opt/openclash/rt/sbin/openclash-uninstall`
- 要求：systemd、glibc ≥ 2.31、x86_64，以及 bash curl unzip nft ip ss nsenter flock ps（缺了安装脚本会告诉你用哪条命令装）。
  装之前先停掉机器上别的 Clash/mihomo 服务（端口会冲突）。

## 怎么跑起来的

```
systemd
├─ openclash-ubusd    ubusd
├─ openclash-rpcd     rpcd：登录会话/ACL/UCI；ucode 插件 openclash-network 模拟 netifd 的 network.interface*
│                     （启动前 openclash-boot：建 /tmp/lock 等目录、首次生成 /etc/config/network）
├─ openclash-procd    OpenWrt 的 procd，以非 PID 1 模式运行：只连 ubus、托管服务实例（mihomo 内核、watchdog、crond、dnsmasq）
├─ openclash-uhttpd   uhttpd + LuCI
└─ openclash-rc       openclash-rcS：像 OpenWrt 开机一样跑 /etc/rc.d/S*（S19dnsmasq、S19firewall=fw4、S50cron、S99openclash），关机跑 K*
```

上游脚本写死了很多 OpenWrt 路径（`/bin/sh` 是 busybox、`/etc/init.d/` 里是 rc.common 脚本、`/sbin/uci`……）。
`install.sh` 对这些路径逐个处理：**宿主上没有的直接建符号链接；宿主上已有同名的（如 `/bin/sh`→dash、发行版的 `/etc/init.d`），
只在 openclash-* 服务的挂载命名空间里换掉**（`/etc/systemd/system/openclash-.service.d/view.conf` 的 `BindPaths`、`PrivateMounts=yes`），宿主不受影响。

`/bin/sh` 要特别处理：上游脚本只能用 busybox ash 跑（bash 当 sh 会把 nft 规则里不带引号的 `{tcp,udp}` 展开），上游又有 `#!/bin/bash` 的脚本。
Debian/Ubuntu 的 `/bin/sh`→dash，bind mount 会挂到 dash 上，没问题；Fedora/RHEL/Arch/openSUSE 的 `/bin/sh`→bash，bind mount 会把 bash 本身换掉。
所以几个服务的 ExecStart 前面加了 `openclash-view`：`/bin/sh` 是 bash 时，它用新挂载 API（`open_tree`+`move_mount`，内核 ≥ 5.2）
把 busybox 挂在 `/bin/sh` 这个符号链接本身上（不跟随到 bash），再执行原命令；和 PID 1 在同一挂载命名空间时拒绝挂载。

要在这个「OpenWrt 视图」里手动执行命令，用 `openclash-run`：

```sh
sudo /opt/openclash/rt/sbin/openclash-run /etc/init.d/openclash restart
sudo /opt/openclash/rt/sbin/openclash-run opkg status luci-app-openclash
```

## 文件

| 文件 | 作用 |
|---|---|
| `release.sh` | 出安装包：建 Debian 11 chroot，在里面跑 `build.sh`、`pack-openclash.sh`，打成自解压的 `.run` |
| `build.sh` | 下载锁定版本的源码，打 OpenWrt 自己的包补丁，编译，打包成 `~/build/openclash-linux/openclash-rt-<arch>.tar.gz` |
| `pack-openclash.sh` | 从上游源码打出 `luci-app-openclash_<版本>_all.ipk`（让 make 直接执行上游 Makefile，再用 OpenWrt 的 ipkg-build） |
| `install.sh` | 安装运行时包、视图、配置、systemd 单元，用 opkg 装 ipk，放行宿主防火墙，启动 |
| `uninstall.sh` | `opkg remove` 上游包，停服务，撤销防火墙放行，按安装清单删除全部安装内容（装好后在 `/opt/openclash/rt/sbin/openclash-uninstall`） |
| `files/systemd/*.service` | 上面 5 个单元 |
| `files/opt/openclash/rt/sbin/openclash-{boot,rcS,run,uhttpd}` | 开机准备、rc.d 启停、进入视图执行命令、按 `/etc/config/uhttpd` 拼 uhttpd 命令行 |
| `files/opt/openclash/rt/sbin/openclash-hostfw` | 放行宿主防火墙（firewalld/ufw）和 Docker 的 `DOCKER-USER` 链，见「宿主防火墙」 |
| `files/openclash-view.c` | 见上面 `/bin/sh` 的说明（`build.sh` 编译进运行时包） |
| `files/opt/openclash/root/etc/init.d/uhttpd` | 视图里的 `/etc/init.d/uhttpd`：转给 systemd（上游改完 uhttpd 配置会 restart 它） |
| `files/usr/share/rpcd/ucode/openclash-network` | ubus `network.interface*`（netifd 的替身），fw4 和上游 `openclash_get_network.lua` 用 |
| `files/etc/config/{uhttpd,rpcd,luci,firewall,system,dhcp}` | 初始 UCI 配置（目标不存在时才装）；firewall 全放行，只为建出 `table inet fw4`；dhcp 只有 dnsmasq 的 DNS 部分，见「DNS 劫持」 |
| `files/usr/share/luci/menu.d/openclash-linux.json` | 唯一的菜单定义：3 个系统页挂在 `admin/services/openclash/sys-*` |
| `files/www/luci-static/resources/menu-bootstrap.js` | 替换主题页头菜单：不显示顶层分类，OpenClash 子菜单横排成页签，右上角只留「退出」 |
| `files/usr/libexec/syslog-wrapper` | 系统日志页：读 journald，按 OpenWrt `logread` 格式输出 |
| `files/openclash-linux.zh_Hans.po` | 菜单里 LuCI 没有的词条（「系统状态」） |

## 依赖

出包机（任意有 sudo 的 Linux，WSL 也行）：`debootstrap`。编译工具由 `release.sh` 装进 Debian 11 chroot，不装到本机。
不经 `release.sh`、直接在本机跑 `build.sh` 时要：gcc、make、cmake、pkg-config、git、curl、bzip2、xz、patch、perl、fakeroot。

运行机：systemd、glibc ≥ 2.31、内核 ≥ 5.2（`/bin/sh` 是 bash 时要用新挂载 API），以及命令 bash、curl、unzip、nft、ip、ss、nsenter、flock、ps。
Lua、ruby、json-c、libcrypt、libyaml 都自带，不用装。缺命令时安装包会按包管理器给出安装命令：

| 包管理器 | 命令 |
|---|---|
| apt | `sudo apt install curl unzip nftables iproute2 util-linux procps` |
| dnf | `sudo dnf install curl unzip nftables iproute util-linux procps-ng` |
| pacman | `sudo pacman -S curl unzip nftables iproute2 util-linux procps-ng` |
| zypper | `sudo zypper install curl unzip nftables iproute2 util-linux procps` |

`ps` 必须是 procps 的（见「注意」）。

## 版本锁定

全部取自 OpenWrt **v24.10.8**（`0b795ce7`）：基础组件来自各包 Makefile 的 `PKG_SOURCE_VERSION`，LuCI 来自 `feeds.conf.default`。

| 组件 | 仓库 | commit |
|---|---|---|
| libubox | git.openwrt.org/project/libubox.git | `49056d178f42da98048a5d4c23f83a6f6bc6dd80` |
| ubus（含 lua 绑定） | git.openwrt.org/project/ubus.git | `60e04048a0e2f3e33651c19e62861b41be4c290f` |
| uci（含 lua 绑定） | git.openwrt.org/project/uci.git | `16ff0badbde7e17ec3bd1f827ffe45922956cf86` |
| rpcd（session/uci 内置，file、ucode 插件） | git.openwrt.org/project/rpcd.git | `bba95191ff2f22c9118a1ba1355b83afaa277ae3` |
| uhttpd（ubus、ucode 处理器） | git.openwrt.org/project/uhttpd.git | `7e64e8bad2415cec0a6d9770ec379db54273c7a7` |
| jsonfilter | git.openwrt.org/project/jsonpath.git | `8a86fb78235b5d7925b762b7b0934517890cc034` |
| libnl-tiny（luci-lib-ip 需要） | git.openwrt.org/project/libnl-tiny.git | `c0df580adbd4d555ecc1962dbe88e91d75b67a4e` |
| cgi-io（packages feed `23abaa6f`） | git.openwrt.org/project/cgi-io.git | `31cb3c89f02d918d7f17bf62a80c852fc38a1ca1` |
| udebug（procd 依赖） | git.openwrt.org/project/udebug.git | `edeb4d6dc690acb476a47e6b11633b5632b08437` |
| procd | git.openwrt.org/project/procd.git | `c59f2d801f6a1b3740a8f08b2fcfe3cfb274699a` |
| opkg | git.openwrt.org/project/opkg-lede.git | `38eccbb1fd694d4798ac1baf88f9ba83d1eac616` |
| firewall4（fw4，ucode 脚本） | git.openwrt.org/project/firewall4.git | `18fc0ead19faf06b8ce7ec5be84957278e942dfa` |
| OpenWrt 主仓库（只取 rc.common、functions.sh、procd.sh、cron 脚本、ipkg-build、包补丁） | git.openwrt.org/openwrt/openwrt.git | `0b795ce79e23b553aa184080c390f9ce92a2b6d4` |
| LuCI（openwrt-24.10 分支） | git.openwrt.org/project/luci.git | `cac97ed67cfbcad90db49f5f3b1245c2c4cbfae5` |
| ucode | github.com/jow-/ucode | `3f64c8089bf3ea4847c96b91df09fbfcaec19e1d` |
| liblucihttp | github.com/jow-/lucihttp | `9b5b683fbb2bb0010aa031d620d0ab8105516757` |
| busybox（静态） | busybox.net 1.36.1 | sha256 `b8cc24c9…de314` |
| Lua 5.1.5（打 OpenWrt 的补丁，含 LNUM） | lua.org | sha256 `2640fc56…95333` |
| json-c 0.18（打 OpenWrt 的补丁） | json-c releases | sha256 `602cdefc…1c160` |
| libxcrypt 4.4.36（rpcd 校验 `/etc/shadow`） | github.com/besser82/libxcrypt | sha256 `e5e1f4ca…d8943` |
| libyaml 0.2.5 | pyyaml.org | sha256 `c642ae9b…78ef4` |
| ruby 3.3.10（上游 YAML.rb/uci.rb 用；不带 rubygems） | ruby-lang.org | sha256 `b555baa4…0e928` |
| dnsmasq 2.93（打 OpenWrt 的 2 个补丁；带 nftset、ubus，不编 DHCP/TFTP/认证 DNS） | thekelleys.org.uk | sha256 `0c00d4e5…2bc19` |
| libmnl 1.0.5（dnsmasq 的 nftset 用） | netfilter.org | sha256 `274b9b91…d0525` |
| libnftnl 1.3.1（**比 OpenWrt 24.10.8 的 1.2.8 新**，见下） | netfilter.org | sha256 `607da28d…ffba8` |
| nftables 1.1.6（只用库 libnftables；**比 OpenWrt 24.10.8 的 1.1.1 新**，见下） | netfilter.org | sha256 `372931bd…2530c` |

ucode 和 lucihttp 没有 openwrt 名下的镜像，OpenWrt 自己的 Makefile 也是从 jow-（OpenWrt 维护者）的仓库取，按 commit 锁定。

nftables / libnftnl 是唯一没有跟 OpenWrt 24.10.8 版本的：`nft` 命令用的是宿主发行版的（往往比 1.1.1 新），
libnftables 1.1.1 读到新版 `nft` 建的集合元数据时会调用空函数指针（`set_make_key` 没检查 `parse_udata`），
dnsmasq 一往 fw4 的集合里加地址就段错误（宿主 nft 1.1.6 实测）。OpenWrt 上命令和库是同一版本，没有这个问题。

**和 OpenWrt 一样打的包补丁**（`build.sh` 的 `owrt_patches`，取自同一版本主仓库的 `package/*/patches`）：
ucode 1 个、uhttpd 17 个（多为安全修复）、rpcd 11 个、jsonfilter 1 个、dnsmasq 2 个、Lua 和 json-c 各按 OpenWrt 的 `patches` 目录。

**我们自己对 OpenWrt 组件的改动**（都在 `build.sh` 里，带断言，源码变了会直接报错）：

| 组件 | 改动 | 原因 |
|---|---|---|
| rpcd | ACL、ucode 脚本、exec 插件目录改回 `/usr/share/rpcd`、`/usr/libexec/rpcd` | 原本跟随安装前缀 `/opt/openclash/rt` |
| procd | ubus `system reboot`、`sysupgrade` 直接返回「不支持」 | 非 PID 1 时 reboot 会走到停机流程 `kill(-1)`（杀掉宿主全部进程），sysupgrade 会在 procd 里 chroot+exec |
| procd | 关掉 `-Wunused-function -Wformat-overflow` 告警；glibc < 2.38 时补一个 `strlcpy` | `DISABLE_INIT` 这条编译路径在新 gcc 下有两处告警；Debian 11 的 glibc 没有 `strlcpy` |
| procd | 实例的 `group nogroup` 查不到时用 gid 65534 | 上游用 nogroup 跑内核，防火墙按 `skgid 65534` 放过内核自己的流量；Fedora 没有 nogroup（65534 叫 nobody），内核按 root 跑，直连流量被送回 TUN 形成回环 |
| 全部 C 组件 | 强制包含一个只声明 `vasprintf` 的头文件 | ucode 用 `vasprintf`，glibc 2.31 只在 `_GNU_SOURCE` 下声明，各项目对 `_GNU_SOURCE` 的定义互相冲突 |
| LuCI dispatcher.uc | ubus 连接从模块顶层挪到 `dispatch()` 开头 | uhttpd 在父进程加载调度器，fork 出的请求子进程共用一条连接，带会话的并发请求会互相读走回复而挂住（WSL 实测 6/6 挂；改后 8/8 在 0.03 秒内返回） |
| busybox | 关掉 top 的 CPU 列和小数 | 和 OpenWrt 一致，LuCI 进程页按这个格式解析 |
| dnsmasq | 编译时去掉 DHCP、TFTP、认证 DNS、ipset | 旁路由盒子上不能冒出第二个 DHCP 服务器；即使把路由器的 `/etc/config/dhcp` 整个拷过来，启动脚本也会按编译特性丢掉 `dhcp-*` 选项 |
| dnsmasq 启动脚本 | 降权用户从 `dnsmasq` 改成 `nobody`，去掉 `--group=dnsmasq` | OpenWrt 装包时会建 dnsmasq 用户和组，各发行版不一定有；不往宿主加账号 |
| dnsmasq 启动脚本 | `boot` 不再设 `BOOT=1` | 原版开机时不加 `--interface`（那时 netifd 还没把接口拉起来，之后靠接口事件 reload）；我们的开机脚本在网络就绪后才跑，也没有接口事件 |
| nftables | 4 处 `case` 标签后补一个空语句 | 标签后直接跟声明 gcc 11 起才接受，Debian 11 是 gcc 10 |

上游 OpenClash **没有打任何补丁**（方案里原计划的 `openclash_get_network.lua` 补丁不需要了，network 垫片让它原样工作）。

## 编译、打包

```sh
git clone https://github.com/vernesong/OpenClash ../OpenClash   # 上游源码（pack-openclash.sh 用 git archive 取）
bash release.sh           # 出安装包 ~/build/openclash-linux/openclash-linux-<版本>-<arch>.run（上游源码默认 ../OpenClash/luci-app-openclash）
```

`release.sh` 第一次会 debootstrap 一个 Debian 11 chroot（`~/build/openclash-linux/chroot-bullseye`），本目录和上游仓库只读挂进去，
编译目录是 chroot 里的 `/build`。也可以不经 chroot 直接在本机编（产物只能在 glibc 不低于本机的系统上用）：

```sh
bash build.sh             # 默认工作目录 ~/build/openclash-linux，可用 WORK=... 指定；源码要放在 Linux 文件系统里（脚本会拒绝 /mnt/*）
bash pack-openclash.sh    # 默认取 ../OpenClash/luci-app-openclash，也可以把上游源码目录作为参数
```

- 再次运行会跳过已完成的步骤；想重做某一步：删 `stamp/` 下对应的文件（chroot 里是 `chroot-bullseye/build/stamp/`）。
- 每个组件的编译日志在 `build/<组件>.log`。

## 安装 / 卸载

```sh
sudo sh openclash-linux-0.48.011-x86_64.run                         # 首次安装：监听 <LAN IP>:80，装 ipk，运行开机脚本
sudo sh openclash-linux-0.48.011-x86_64.run --listen 0.0.0.0:8080   # 指定监听地址（80 被占用时用这个）
sudo sh openclash-linux-0.48.011-x86_64.run --no-boot               # 只起网页栈和 procd，不启动 fw4/cron/OpenClash（调试用）
sudo sh openclash-linux-0.48.011-x86_64.run --login-user alice      # 网页另外允许系统用户 alice 用自己的密码登录（默认是执行 sudo 的用户）
sudo /opt/openclash/rt/sbin/openclash-uninstall
```

再次运行新版本的安装包就是升级（配置保留）。安装包解压后执行的就是本目录的 `install.sh --ipk <ipk> <运行时包>`。

只升级 OpenClash 插件不用重装：网页「检查更新」里的插件更新、「历史版本」降级都和路由器上一样，走上游的
`openclash_update.sh`（下载 ipk → `opkg --noaction` 预检 → 由 procd 起一个更新服务执行 `opkg install`）。
预检不过（包损坏、依赖不满足）直接退出，旧版不动；配置和 `/etc/openclash` 里的文件保留。上游没有自动回滚，
装坏了就从「历史版本」装回旧版。容器里实测过：升级、坏包被拦、降级回原版（见下面「测试」）。

- 「本机 DNS 劫持」的默认值和上游一样是 **dnsmasq 转发**（模式 1），见下面「DNS 劫持」。从旧版本升级上来的保持原来的设置（旧版本首次安装时设成了模式 2）。
- `/etc/config/network` 由 openclash-boot 首次按网卡生成：单网卡 = `lan`；两张网卡时默认路由那张 = `wan`、另一张 = `lan`。
  之后每次启动只刷新各接口的 `ipaddr`。改了接口要 `sudo systemctl restart openclash-rpcd`。
- 已存在的 `/etc/config/*` 不覆盖；安装清单在 `/opt/openclash/rt/.manifest`，重装时会删掉上次装了、这次没有的文件。
  清单里结尾带 `/` 的是目录：卸载和升级清理时目录只会在空了以后 `rmdir`，绝不当文件删
  （运行时包里有 `/lib`、`/sbin`，合并 /usr 的发行版上它们是指向 `usr/` 的符号链接，删了系统起不来）；根目录下的条目一律不删。
- 登录用系统 root 密码（rpcd `$p$root`，校验 `/etc/shadow`），和 OpenWrt 一样。另外 install.sh 会再加一个系统用户（默认是执行 sudo 的人，`--login-user` 可指定），用他自己的密码登录：Ubuntu 默认锁定 root，NAS 之类的系统 root 密码是装机时设的、用户不知道（飞牛 NAS 实测）。这个用户在网页上拥有全部权限，等同 root。
- 卸载会走上游的 postrm：删除 `/etc/openclash` 和 `/etc/config/openclash`（和 OpenWrt 上卸载一样）。

## DNS 劫持（模式 1：dnsmasq 转发）

和路由器上一样：dnsmasq 由 OpenWrt 原版启动脚本按 `/etc/config/dhcp` 生成配置、交给 procd 托管；OpenClash 启动时把它的上游改成
内核的 DNS 端口（`127.0.0.1#7874`），并在 fw4 里把局域网发往任何地址的 53 端口请求重定向到 dnsmasq；停止时还原。
「指定 DNS 服务器」「大陆绕过例外列表」这两个只在模式 1 出现的选项靠 dnsmasq 的 `server=` 和 `nftset=` 实现
（例外域名解析出的地址由 dnsmasq 写进 fw4 的 `china_ip_route_pass` 集合）。

和路由器不同的地方：

- **不占 systemd-resolved 的地址**：dnsmasq 只在局域网网卡的地址和 `127.0.0.1` 上监听（`interface 'lan'` + `nonwildcard`），
  `127.0.0.53`、`127.0.0.54` 以及 Docker、隧道等网卡的地址都不碰；宿主自己的 `/etc/resolv.conf` 不改，宿主照旧用它原来的 DNS。
- **上游 DNS**：OpenClash 停着时 dnsmasq 转发给本机实际使用的 DNS 服务器。`openclash-boot` 每次启动把它们写进
  `/tmp/resolv.conf.d/resolv.conf.auto`（OpenWrt 上由 netifd 写）：有 systemd-resolved 时取 `/run/systemd/resolve/resolv.conf`
  里的真实服务器，否则取 `/etc/resolv.conf`，回环地址一律跳过。
- **53 端口被占用时**：首次安装发现 53 已被别的程序占用（监听全部地址、`127.0.0.1` 或局域网地址）就把 dnsmasq 改到 5335 端口
  （`/etc/config/dhcp` 的 `port`）。OpenClash 运行时不受影响（劫持规则按这个端口重定向），只是它停着时盒子的 53 端口没人应答。
- **没有 DHCP**：见上面改动表。局域网的地址分配仍由主路由负责；要让设备走盒子，在主路由的 DHCP 里把网关（和 DNS）指向盒子，或在设备上手动设置。
- dnsmasq 以 `nobody` 运行，`ubus` 选项关闭（OpenWrt 上是给 DHCP 事件用的）。

不想用 dnsmasq 可以在「插件设置 → DNS 设置 → 本机 DNS 劫持」改成「防火墙转发」（模式 2），局域网的 DNS 请求直接重定向到内核。

## 宿主防火墙

nftables 里别的表丢弃的包，fw4 放行也没用，所以 `openclash-hostfw` 直接改宿主自己的防火墙（install.sh 和每次开机脚本调用，卸载时撤销）：

- **firewalld**：在局域网网卡所在区域（网卡没绑区域时用默认区域，并把网卡加进去）开网页、53（和 dnsmasq 改过的端口）、OpenClash 各端口（tcp+udp），
  开区域内转发（`forward`），把 `utun` 加进同一区域。**只加区域里原来没有的**：已在端口范围里的端口不加
  （firewalld 往范围里加单个端口会把范围拆开，撤销后范围就缺了这个端口）；区域原本就开着的 `forward` 不会被卸载关掉。运行时和永久配置都改。
- **ufw**：在局域网网卡上放行这些端口，允许局域网网卡、`utun` 的转发。
- **Docker**：Docker 把 iptables `FORWARD` 默认策略设成 DROP，旁路由转发会被丢。在它留给用户的 `DOCKER-USER` 链里只放行
  局域网网卡 ↔ 同一网卡、局域网网卡 ↔ `utun`，不放行到容器网段。

做过的改动以撤销命令的形式记在 `/opt/openclash/rt/.hostfw`。

## 测试

- 启动 OpenClash、改 nft/路由的测试只在网络命名空间里做：全部 openclash-* 服务临时放进命名空间
  （`/run/systemd/system/openclash-.service.d/netns.conf` 写 `NetworkNamespacePath=/run/netns/<名字>`，`daemon-reload` 后再启动），
  另建客户端和「上游」命名空间；启动前确认每个单元的 `NetworkNamespacePath` 已生效。在 WSL（Ubuntu 26.04）里这样测过
  全部页面和接口、写操作、更新、DNS 模式 1 和 2 × 6 种运行模式、黑白名单、IPv6（4 种 IPv6 代理模式）、kill -9 拉起、停止清理。
- 其他发行版用 `systemd-nspawn -b --private-network` 容器测（Debian 11、Fedora 44 + firewalld）：装、重复装、网页登录、
  插件经网页升级/坏包被拦/降级、卸载后整个文件系统和防火墙（含 firewalld 运行时/永久配置）与安装前逐条对比。
- 实机：飞牛 fnOS（Debian 12 系）上用真实订阅测过 6 种运行模式（TCP 和 UDP 经节点）、只代理指定设备、本机流量不受影响。
- 测试脚本（命名空间拓扑、容器、实机远程安全网）没有放进这个仓库。
- 用不显示的浏览器窗口（自动化）打开网页时页面会一直停在「载入视图」：LuCI 把 RPC 请求攒到下一次重绘（`requestAnimationFrame`）才发，
  窗口不重绘就不发。不是服务端的问题。

## 注意

1. **视图里的 `ps` 必须是 procps 的，不能换成 busybox。** 上游网页的启停接口会执行
   `ps | grep -E 'openclash|clash|mihomo' | awk '{print $1}' | xargs kill -9`。procps 的 `ps -efw` 第一列是用户名，这行实际杀不到东西；
   busybox `ps` 第一列是 PID，会把 `/opt/openclash/rt` 下的网页栈和机器上别的 mihomo 服务一起杀掉。
2. `/etc/rc.d`、`/etc/openwrt_release`、`/sbin/uci` 等 OpenWrt 路径会出现在宿主上（宿主没有时建的符号链接/文件），都记在安装清单里，卸载时删除。
3. procd 发现 `/sys/fs/cgroup` 可写会在宿主 cgroup 根下建 `services/` 子树，所以 openclash-procd 设了 `ProtectControlGroups=yes`，
   实例改为按 PID 管理（日志里每次启动实例有一行 `failed adding instance cgroup` 警告，属正常）。
4. fw4 的状态文件 `/var/run/fw4.state` 存在时，`fw4 start` 会认为已加载而跳过；重启机器后 `/run` 清空，不受影响。
5. 开机脚本和 OpenWrt 一样打开 IPv4、IPv6 转发（`net.ipv4.ip_forward`、`net.ipv6.conf.all.forwarding`）。IPv6 转发不开时，
   IPv6 的 TUN/混合模式和不经内核的 IPv6 直通流量都不通（装了 Docker 的机器上 Docker 已经打开了）。开 IPv6 转发前把 `accept_ra=1`
   的网卡改成 `2`，否则内核不再接受 RA，宿主自己的 IPv6 默认路由会到期消失；NetworkManager、systemd-networkd 管的网卡自己处理 RA，不受影响。
   卸载不会把转发关回去。

## 已知问题

1. SELinux（Fedora 默认 Enforcing）还没在实机上验证：容器里测不了。
2. 没编 TLS（只走 HTTP，和方案 §4.4 一致）。
3. `/etc/config/*` 由 uci 改写后，模板里的注释会消失。
4. 系统状态页没有网络/DHCP/无线块（需要 `luci-rpc`）；浏览器控制台里登录页有一条 `uci/get Access denied`（匿名会话，OpenWrt 上也有）。
5. 系统日志只取 journald 最近 1000 条，要更多改 `syslog-wrapper` 里的 `-n`。
6. 服务刚重启后马上登录偶尔返回登录页（rpcd 还没就绪），再登一次即可。
7. 没编 ubox 的 `validate_data`：cron 启动脚本的参数校验会打一行 `/sbin/validate_data: not found`，不影响运行。
8. 没有 `brctl`：上游读网络信息时会打 `brctl: not found`，不影响结果。
9. 宿主自己的域名解析不经过 dnsmasq（`/etc/resolv.conf` 没改）：宿主自己发出的流量按 IP 规则分流，域名规则对它不起作用。
   路由器上「路由器自身」的请求是走 dnsmasq → 内核的。
10. 卸载后 `/tmp` 下运行时生成的文件（`/tmp/etc`、`/tmp/dnsmasq.*.d`、`/tmp/resolv.conf*`、`/tmp/hosts` 等）留到下次重启才消失。
