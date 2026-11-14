#!/usr/bin/env bash
# 安装 build.sh 产出的运行时包（OpenWrt 网页栈 + procd/opkg/fw4 等系统组件）、OpenWrt 视图、systemd 单元，
# 再用 opkg 装上 pack-openclash.sh 打出的 luci-app-openclash ipk，然后启动。
# 用法：sudo ./install.sh [--listen 地址:端口] [--ipk 文件] [--no-boot] [运行时包.tar.gz]
#   --listen   uhttpd 监听地址；不给且是首次安装时，自动取默认路由网卡的 IPv4 + 80 端口
#   --ipk      luci-app-openclash 的 ipk；默认取 ~/build/openclash-linux/ 下最新的，已装同版本时跳过
#   --no-boot  只起网页栈和 procd，不跑开机脚本（不启动 fw4、cron、OpenClash），调试用
#   --login-user 用户名  网页除了 root 以外还允许这个系统用户用自己的密码登录；不给时默认是执行 sudo 的那个用户
#              （root 被锁定、或 root 密码不知道的系统上就靠它；这个用户在网页上拥有全部权限，等同 root）
set -Eeuo pipefail

RT=/opt/openclash/rt
VROOT=/opt/openclash/root
MANIFEST=$RT/.manifest
HERE=$(cd "$(dirname "$0")" && pwd)
UNITS=(openclash-ubusd openclash-rpcd openclash-procd openclash-uhttpd openclash-rc)
DROPIN=/etc/systemd/system/openclash-.service.d/view.conf

die() { echo "错误：$*" >&2; exit 1; }
trap 'echo "错误：第 $LINENO 行失败：$BASH_COMMAND" >&2' ERR

BUILD=$(getent passwd "${SUDO_USER:-root}" | cut -d: -f6)/build/openclash-linux
LISTEN= IPK= BOOT=1 LOGIN_USER=${SUDO_USER:-}
PKG=$BUILD/openclash-rt-$(uname -m).tar.gz
while (($#)); do
	case $1 in
		--listen) LISTEN=${2:?--listen 需要参数，如 192.168.1.10:80}; shift 2 ;;
		--ipk) IPK=${2:?--ipk 需要 ipk 文件}; shift 2 ;;
		--no-boot) BOOT=0; shift ;;
		--login-user) LOGIN_USER=${2:?--login-user 需要系统用户名}; shift 2 ;;
		-h|--help) sed -n '2,10p' "$0"; exit 0 ;;
		*) PKG=$1; shift ;;
	esac
done
[[ -n $IPK ]] || IPK=$(ls -t "$BUILD"/luci-app-openclash_*_all.ipk 2>/dev/null | head -n1) || true

((EUID == 0)) || die "请用 root 运行（sudo $0）"
[[ -d /run/systemd/system ]] || die "需要 systemd"
[[ -f $PKG ]] || die "找不到运行时包 $PKG，请先运行 build.sh，或把包路径作为参数传入"
# 运行时包在 Debian 11 里编译（release.sh），自带 Lua、ruby 和依赖库，只要求 glibc ≥ 2.31
glibc=$(getconf GNU_LIBC_VERSION 2>/dev/null | awk '{print $2}')
[[ -n $glibc && $(printf '%s\n' 2.31 "$glibc" | sort -V | head -n1) == 2.31 ]] || die "需要 glibc ≥ 2.31（本机：${glibc:-不是 glibc}）"
# 上游 OpenClash 后端还要用的系统命令，各发行版都有，只是包名略有不同
# ps 必须是 procps 的：上游网页的启停接口会 `ps | grep -E "openclash|clash|mihomo" | awk "{print $1}" | xargs kill -9`，
# procps 的 ps -efw 第一列是用户名所以不会误杀；换成 busybox ps（第一列是 PID）就会杀掉网页栈和别的 mihomo 服务
miss=()
for c in bash curl unzip nft ip ss nsenter flock ps; do command -v $c >/dev/null || miss+=("$c"); done
if ((${#miss[@]})); then
	if command -v apt-get >/dev/null; then cmd="apt install curl unzip nftables iproute2 util-linux procps"
	elif command -v dnf >/dev/null; then cmd="dnf install curl unzip nftables iproute util-linux procps-ng"
	elif command -v pacman >/dev/null; then cmd="pacman -S curl unzip nftables iproute2 util-linux procps-ng"
	elif command -v zypper >/dev/null; then cmd="zypper install curl unzip nftables iproute2 util-linux procps"
	else cmd="用发行版的包管理器安装 curl、unzip、nftables、iproute2、util-linux、procps"; fi
	die "缺少命令：${miss[*]}。请执行：sudo $cmd"
fi

# 首次安装且没指定 --listen：探测 LAN 地址，默认 80 端口
if [[ -z $LISTEN && ! -f /etc/config/uhttpd ]]; then
	ip=$(ip -4 route get 1.1.1.1 2>/dev/null | sed -n 's/.* src \([0-9.]*\).*/\1/p')
	[[ -n $ip ]] || die "探测不到 LAN 地址，请用 --listen <LAN IP>:80 指定"
	LISTEN=$ip:80
fi
if [[ -n $LISTEN && -n $(ss -Hltn "sport = :${LISTEN##*:}") ]]; then
	systemctl is-active -q openclash-uhttpd || die "端口 ${LISTEN##*:} 已被占用，请改用 --listen ${LISTEN%:*}:8080"
fi

echo ">>> 解包 $PKG"
# 先停开机脚本单元：它的停止动作会按 OpenWrt 关机流程停掉 OpenClash、撤掉规则
systemctl stop openclash-rc.service 2>/dev/null || true
systemctl stop "${UNITS[@]/%/.service}" 2>/dev/null || true
# 安装清单：目录条目保留结尾的 /。卸载和升级清理时，目录条目只会被 rmdir（空了才删），不带 / 的条目才当文件删——
# 运行时包里有 /lib、/sbin 这些目录，在合并 /usr 的发行版上它们是指向 usr/ 的符号链接，绝不能当文件删
list=$(tar -tzf "$PKG" | sed 's|^\./||; s|^|/|')
# --keep-directory-symlink：/lib、/sbin 在合并 /usr 的发行版上是符号链接，不能被换成目录
tar -xzf "$PKG" -C / --no-overwrite-dir --keep-directory-symlink
# 我们自己的文件（垫片、菜单、主题、启动脚本），同名的覆盖运行时包里的
while read -r f; do
	case $f in */libexec/*|*/bin/*|*/sbin/*|*/init.d/*) m=755 ;; *) m=644 ;; esac
	install -Dm$m "$HERE/files/$f" "/$f"
	list+=$'\n'/$f
done < <(cd "$HERE/files" && find usr www opt -type f)
install -m755 "$HERE/uninstall.sh" "$RT/sbin/openclash-uninstall"
list+=$'\n'$RT/sbin/openclash-uninstall

# OpenWrt 视图：上游脚本写死的这些路径，宿主上没有就直接装（符号链接）；宿主上已有同名的（如 /bin/sh 是 dash、
# /etc/init.d 是发行版的），只在 openclash-* 服务的挂载命名空间里换掉，宿主不受影响
VIEW=(
	/bin/sh=$RT/bin/busybox
	/usr/sbin/crond=$RT/bin/busybox
	# 自带的 dnsmasq（DNS 劫持模式 1）：OpenWrt 的启动脚本写死这个路径，上游也按它的编译特性决定用不用 nftset
	/usr/sbin/dnsmasq=$RT/sbin/dnsmasq
	# 上游按 busybox 的输出格式解析（ifconfig | grep "inet6 addr"），net-tools 的格式不一样
	/sbin/ifconfig=$RT/bin/busybox
	# 上游用 crontab 通知 crond；宿主的 crontab 和 /var/spool/cron/crontabs 属于发行版的 cron，视图里换成 busybox 的
	/usr/bin/crontab=$RT/bin/busybox
	/var/spool/cron/crontabs=/etc/crontabs
	# 自带的 Lua 5.1（OpenWrt 的补丁），上游脚本的 #!/usr/bin/lua 要用它
	/usr/bin/lua=$RT/bin/lua
	# 自带的 ruby：uhttpd 给 CGI 的 PATH 固定是 /sbin:/usr/sbin:/bin:/usr/bin，网页发起的启动只能按这个找 ruby
	/usr/bin/ruby=$RT/bin/ruby
	/etc/init.d=$VROOT/etc/init.d
	/etc/rc.d=$VROOT/etc/rc.d
	/sbin/uci=$RT/bin/uci
	/bin/ubus=$RT/bin/ubus
	/bin/opkg=$RT/bin/opkg-cl
	/usr/bin/jsonfilter=$RT/bin/jsonfilter
	/usr/bin/jshn=$RT/bin/jshn
	/usr/bin/ucode=$RT/bin/ucode
	/usr/bin/utpl=$RT/bin/utpl
	/var/etc=/tmp/etc
	/var/state=/tmp/state
)
binds=()
for e in "${VIEW[@]}"; do
	dst=${e%%=*} src=${e#*=}
	# RHEL 一类的 /etc/init.d → /etc/rc.d/init.d：遮住 /etc/rc.d 就够了（视图目录的 rc.d/init.d 里就是脚本）
	[[ $dst == /etc/init.d && $(readlink -f /etc/init.d) == /etc/rc.d/* ]] && continue
	# Fedora 一类的 /bin/sh → bash：bind mount 会把 bash 本身换成 busybox（上游也有 #!/bin/bash 脚本），
	# 交给各服务 ExecStart 前面的 openclash-view 挂到符号链接本身上
	[[ $dst == /bin/sh && $(readlink -f /bin/sh) == */bash ]] && continue
	if [[ ! -e $dst && ! -L $dst ]] || [[ $(readlink "$dst") == "$src" ]]; then
		mkdir -p "${dst%/*}" && ln -sfn "$src" "$dst"
		list+=$'\n'$dst
	elif [[ $(readlink -f "$dst") == "$(readlink -f "$src")" ]]; then
		: # 宿主上已经是同一个文件
	else
		# 宿主上是符号链接时，bind mount 会挂到它最终指向的文件上（例如 /bin/sh → dash），视图里那个文件被换掉
		binds+=("$src:$dst")
	fi
done
# OpenWrt 的 cron 启动脚本在 /etc/crontabs 为空时不启动 crond，放一个空的 root
[[ -e /etc/crontabs/root ]] || { touch /etc/crontabs/root; list+=$'\n'/etc/crontabs/root; }
# LuCI 的进程页固定调用 /bin/busybox top；系统自己有 busybox 就用系统的
if [[ ! -e /bin/busybox || $(readlink /bin/busybox) == "$RT/bin/busybox" ]]; then
	ln -sfn "$RT/bin/busybox" /bin/busybox
	list+=$'\n'/bin/busybox
fi
mkdir -p "${DROPIN%/*}"
{
	echo "# install.sh 生成：所有 openclash-* 服务共用的 OpenWrt 视图"
	echo "[Service]"
	# 自带的 lua、ruby 排在发行版的前面
	echo "Environment=PATH=$RT/sbin:$RT/bin:/usr/sbin:/usr/bin:/sbin:/bin"
	# 每个服务自己的挂载命名空间，里面的挂载（BindPaths、openclash-view）不传回宿主
	echo "PrivateMounts=yes"
	((${#binds[@]} == 0)) || echo "BindPaths=${binds[*]}"
} >"$DROPIN"
list+=$'\n'$DROPIN

for u in "${UNITS[@]}"; do
	install -m644 "$HERE/files/systemd/$u.service" "/etc/systemd/system/$u.service"
	list+=$'\n'/etc/systemd/system/$u.service
done

# 已有的配置不覆盖；新建的记入清单，卸载时一并删除
mkdir -p /etc/config
for f in "$HERE"/files/etc/config/*; do
	t=/etc/config/${f##*/}
	[[ -e $t ]] || { install -m600 "$f" "$t"; list+=$'\n'$t; [[ $t != */system ]] || "$RT/bin/uci" set system.@system[0].hostname="$(hostname)"; }
done
"$RT/bin/uci" commit system
# dnsmasq 默认用 53 端口（和路由器一样，OpenClash 停着时局域网设备也能拿盒子当 DNS）。首次安装时 53 已被别的程序占用
# （监听全部地址、127.0.0.1 或局域网地址；systemd-resolved 的 127.0.0.53/54 不算）就换一个端口：
# OpenClash 运行时照样把局域网的 DNS 请求劫持到这个端口，只是它停着时盒子的 53 端口没人应答
if grep -qx /etc/config/dhcp <<<"$list"; then
	lanip=$(ip -4 route get 1.1.1.1 2>/dev/null | sed -n 's/.* src \([0-9.]*\).*/\1/p')
	if ss -Hlntu 'sport = :53' | awk '{sub(/:53$/, "", $5); sub(/%.*/, "", $5); print $5}' |
		grep -qxF -e 0.0.0.0 -e '*' -e '[::]' -e 127.0.0.1 -e '[::1]' ${lanip:+-e "$lanip"}; then
		"$RT/bin/uci" set dhcp.@dnsmasq[0].port=5335
		"$RT/bin/uci" commit dhcp
		echo "提示：53 端口已被占用，dnsmasq 改用 5335 端口（OpenClash 运行时不受影响；想用 53 请先停掉占用它的程序，再改 /etc/config/dhcp 的 port）" >&2
	fi
fi

# /etc/openwrt_release：上游按 DISTRIB_ARCH 选内核架构，procd 的 system board 读发行版信息
. /etc/os-release
case $(uname -m) in
	x86_64) arch=x86_64 ;;
	aarch64) arch=aarch64_generic ;;
	armv7l) arch=arm_cortex-a7_neon-vfpv4 ;;
	i?86) arch=i386_pentium4 ;;
	riscv64) arch=riscv64_generic ;;
	loongarch64) arch=loongarch64_generic ;;
	*) die "不支持的架构 $(uname -m)" ;;
esac
cat >/etc/openwrt_release <<EOF
DISTRIB_ID='${NAME}'
DISTRIB_RELEASE='${VERSION_ID:-}'
DISTRIB_REVISION='openclash-linux'
DISTRIB_TARGET='$(uname -m)/generic'
DISTRIB_ARCH='$arch'
DISTRIB_DESCRIPTION='${PRETTY_NAME}'
DISTRIB_TAINTS=''
EOF
echo "${VERSION_ID:-unknown}" >/etc/openwrt_version
# opkg：没有软件源（不从网上装依赖）；依赖由发行版提供，用一个已安装的 openclash-linux 包声明
cat >/etc/opkg.conf <<EOF
dest root /
dest ram /tmp
lists_dir ext /var/opkg-lists
arch all 1
arch noarch 1
arch $arch 10
EOF
list+=$'\n'/etc/openwrt_release$'\n'/etc/openwrt_version$'\n'/etc/opkg.conf
mkdir -p /usr/lib/opkg/info
if ! grep -q '^Package: openclash-linux$' /usr/lib/opkg/status 2>/dev/null; then
	cat >>/usr/lib/opkg/status <<EOF
Package: openclash-linux
Version: 3
Provides: libc, bash, curl, ca-bundle, ip-full, ruby, ruby-yaml, kmod-tun, unzip, dnsmasq-full, luci-base, luci-compat, firewall4, kmod-nft-tproxy, kmod-inet-diag
Status: install user installed
Architecture: all
Installed-Time: $(date +%s)

EOF
fi
: >>/usr/lib/opkg/info/openclash-linux.list

# 重装/升级：上次装了、这次没有的文件删掉（例如旧版的垫片）；上次新建的配置保留并留在清单里
if [[ -f $MANIFEST ]]; then
	# 只删文件和符号链接（清单里不带 / 的条目，且不在根目录下）；目录留着，见上面清单的说明
	while read -r p; do
		[[ $p == /*/* && $p != */ ]] || continue
		[[ -d $p && ! -L $p ]] || rm -f -- "$p"
	done < <(comm -23 <(grep -v '^/etc/config/' "$MANIFEST" | sort -u) <(sort -u <<<"$list"))
	list+=$'\n'$(grep '^/etc/config/' "$MANIFEST" || true)
fi
sort -u <<<"$list" | grep . >"$MANIFEST"
# 菜单缓存，菜单定义变了必须清
rm -rf /tmp/luci-indexcache.* /tmp/luci-modulecache

if [[ -n $LISTEN ]]; then
	"$RT/bin/uci" -q delete uhttpd.main.listen_http || true
	"$RT/bin/uci" add_list uhttpd.main.listen_http="$LISTEN"
	"$RT/bin/uci" commit uhttpd
fi

# 和 OpenWrt 一样用 root 密码登录（rpcd 的 $p$root 校验 /etc/shadow）。但 Ubuntu 默认锁定 root，NAS 之类的系统
# root 密码是装机时设的、用户不知道，所以再允许一个系统用户（默认执行 sudo 的人）用他自己的密码登录
[[ $LOGIN_USER == root ]] && LOGIN_USER=
if [[ -n $LOGIN_USER ]]; then
	getent passwd "$LOGIN_USER" >/dev/null || die "--login-user：没有系统用户 $LOGIN_USER"
	cur=$("$RT/bin/uci" show rpcd)
	if ! grep -qF ".username='$LOGIN_USER'" <<<"$cur"; then
		s=$("$RT/bin/uci" add rpcd login)
		"$RT/bin/uci" set rpcd."$s".username="$LOGIN_USER"
		"$RT/bin/uci" set rpcd."$s".password="\$p\$$LOGIN_USER"
		"$RT/bin/uci" add_list rpcd."$s".read='*'
		"$RT/bin/uci" add_list rpcd."$s".write='*'
		"$RT/bin/uci" commit rpcd
	fi
	echo "网页登录：root 或 $LOGIN_USER，密码是该系统用户自己的密码"
else
	case $(passwd -S root | awk '{print $2}') in
		L|NP) echo "提示：root 当前没有可用密码，网页无法登录。请先执行 sudo passwd root，或重装时加 --login-user <用户名>" >&2 ;;
	esac
fi

echo ">>> 启动网页栈和 procd"
systemctl daemon-reload
systemctl enable openclash-uhttpd.service openclash-rc.service
systemctl restart openclash-uhttpd.service openclash-procd.service
systemctl is-active -q openclash-uhttpd || die "uhttpd 没起来，请查看：journalctl -u 'openclash-*'"
# 宿主防火墙（firewalld/ufw）放行局域网访问网页等（开机脚本每次启动也会按当前端口重新放行）
"$RT/sbin/openclash-hostfw" apply

if [[ -n $IPK ]]; then
	ver=$(tar -xzOf "$IPK" ./control.tar.gz | tar -xzO ./control | sed -n 's/^Version: //p')
	cur=$("$RT/sbin/openclash-run" opkg status luci-app-openclash | sed -n 's/^Version: //p')
	if [[ $ver != "$cur" ]]; then
		echo ">>> 安装 luci-app-openclash $ver（${cur:+原来是 $cur}）"
		"$RT/sbin/openclash-run" opkg install --force-downgrade "$IPK"
	fi
else
	echo "提示：没找到 luci-app-openclash 的 ipk，先运行 pack-openclash.sh，或用 --ipk 指定" >&2
fi

if ((BOOT)); then
	echo ">>> 运行开机脚本（fw4、cron、OpenClash）"
	systemctl restart openclash-rc.service
fi
echo "完成：浏览器打开 http://$("$RT/bin/uci" get uhttpd.main.listen_http | awk '{print $1}')/"
