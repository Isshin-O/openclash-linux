#!/usr/bin/env bash
# 从源码编译 OpenWrt 24.10 的网页栈（ubus/uci/rpcd/uhttpd/ucode/LuCI）和 OpenClash 后端要用的系统组件
# （procd/opkg/fw4/busybox），连同它们依赖的库（Lua、json-c、libxcrypt、libyaml）和 ruby 一起自带，
# 产物以 /opt/openclash/rt 为前缀装进暂存目录，最后打成 tar 包供 install.sh 使用。
# 出通用安装包请用 release.sh（在 Debian 11 chroot 里调用本脚本，产物只要求目标机 glibc ≥ 2.31）。
# 可重复执行：已下载、已编译的步骤靠 stamp 文件跳过；删掉 $WORK/stamp/<步骤> 可强制重做该步。
set -Eeuo pipefail

PREFIX=/opt/openclash/rt
HERE=$(cd "$(dirname "$0")" && pwd)
WORK=${WORK:-$HOME/build/openclash-linux}
SRC=$WORK/src BLD=$WORK/build STAGE=$WORK/stage STAMP=$WORK/stamp
OUT=$WORK/openclash-rt-$(uname -m).tar.gz
JOBS=$(nproc)

trap 'echo "错误：第 $LINENO 行失败：$BASH_COMMAND" >&2; echo "修好后重新运行 build.sh，已完成的步骤会自动跳过。" >&2' ERR

# ---- 版本锁定：取自 openwrt v24.10.8 的包 Makefile 与 feeds.conf.default ----
OWRT=https://git.openwrt.org/project
declare -A URL=(
	[libubox]=$OWRT/libubox.git
	[ubus]=$OWRT/ubus.git
	[uci]=$OWRT/uci.git
	[rpcd]=$OWRT/rpcd.git
	[uhttpd]=$OWRT/uhttpd.git
	[jsonpath]=$OWRT/jsonpath.git
	[libnl-tiny]=$OWRT/libnl-tiny.git
	[cgi-io]=$OWRT/cgi-io.git
	[udebug]=$OWRT/udebug.git
	[procd]=$OWRT/procd.git
	[opkg]=$OWRT/opkg-lede.git
	[firewall4]=$OWRT/firewall4.git
	# OpenWrt 主仓库只取脚本（rc.common、functions.sh、procd.sh、cron 启动脚本、ipkg-build）
	[openwrt]=https://git.openwrt.org/openwrt/openwrt.git
	[luci]=$OWRT/luci.git
	# 这两个没有 openwrt 镜像，OpenWrt 自己的包 Makefile 就从这里取
	[ucode]=https://github.com/jow-/ucode.git
	[lucihttp]=https://github.com/jow-/lucihttp.git
)
declare -A REV=(
	[libubox]=49056d178f42da98048a5d4c23f83a6f6bc6dd80
	[ubus]=60e04048a0e2f3e33651c19e62861b41be4c290f
	[uci]=16ff0badbde7e17ec3bd1f827ffe45922956cf86
	[rpcd]=bba95191ff2f22c9118a1ba1355b83afaa277ae3
	[uhttpd]=7e64e8bad2415cec0a6d9770ec379db54273c7a7
	[jsonpath]=8a86fb78235b5d7925b762b7b0934517890cc034
	[libnl-tiny]=c0df580adbd4d555ecc1962dbe88e91d75b67a4e
	[cgi-io]=31cb3c89f02d918d7f17bf62a80c852fc38a1ca1 # packages feed 23abaa6f 的 net/cgi-io
	[udebug]=edeb4d6dc690acb476a47e6b11633b5632b08437
	[procd]=c59f2d801f6a1b3740a8f08b2fcfe3cfb274699a
	[opkg]=38eccbb1fd694d4798ac1baf88f9ba83d1eac616
	[firewall4]=18fc0ead19faf06b8ce7ec5be84957278e942dfa
	[openwrt]=0b795ce79e23b553aa184080c390f9ce92a2b6d4 # v24.10.8
	[luci]=cac97ed67cfbcad90db49f5f3b1245c2c4cbfae5
	[ucode]=3f64c8089bf3ea4847c96b91df09fbfcaec19e1d
	[lucihttp]=9b5b683fbb2bb0010aa031d620d0ab8105516757
)
# 只检出用得到的目录（主仓库很大）
declare -A SPARSE=(
	[openwrt]="package/base-files/files package/system/procd/files package/system/uci/files package/utils/busybox/files scripts
		package/utils/ucode/patches package/network/services/uhttpd/patches package/system/rpcd/patches package/utils/jsonfilter/patches
		package/utils/lua/patches package/libs/libjson-c/patches package/network/services/dnsmasq"
)
# OpenWrt 编译这些包时会先打的补丁（uhttpd、rpcd 多为安全修复），我们也一样打上
declare -A OWRT_PATCHES=(
	[ucode]=package/utils/ucode/patches
	[uhttpd]=package/network/services/uhttpd/patches
	[rpcd]=package/system/rpcd/patches
	[jsonpath]=package/utils/jsonfilter/patches
	[lua]=package/utils/lua/patches
	[json-c]=package/libs/libjson-c/patches
	[dnsmasq]=package/network/services/dnsmasq/patches
)
# 源码包：版本和 sha256 取自 OpenWrt v24.10.8（lua、json-c、dnsmasq、libmnl）和 packages feed 23abaa6f（ruby、libxcrypt、yaml）
# 的包 Makefile。nftables、libnftnl 例外，用的是比 OpenWrt 24.10.8（1.1.1 / 1.2.8）新的版本，sha256 取自 netfilter.org：
# 这里只用它的库（dnsmasq 的 nftset），而集合是宿主的 nft 命令建的，宿主的 nft 往往更新；1.1.1 读到新版 nft 写的集合元数据
# 会调用空函数指针（set_make_key 没检查 parse_udata），dnsmasq 一往集合里加地址就崩溃。OpenWrt 上命令和库同一版本，没有这个问题
declare -A TARBALL=(
	[busybox]="https://busybox.net/downloads/busybox-1.36.1.tar.bz2 b8cc24c9574d809e7279c3be349795c5d5ceb6fdf19ca709f80cde50e47de314"
	[lua]="https://www.lua.org/ftp/lua-5.1.5.tar.gz 2640fc56a795f29d28ef15e13c34a47e223960b0240e8cb0a82d9b0738695333"
	[json-c]="https://s3.amazonaws.com/json-c_releases/releases/json-c-0.18-nodoc.tar.gz 602cdefc1d2aab8318fc0814b7ce7d59e72514d4276ca3eff92f35f86cf1c160"
	[libxcrypt]="https://github.com/besser82/libxcrypt/releases/download/v4.4.36/libxcrypt-4.4.36.tar.xz e5e1f4caee0a01de2aee26e3138807d6d3ca2b8e67287966d1fefd65e1fd8943"
	[yaml]="https://pyyaml.org/download/libyaml/yaml-0.2.5.tar.gz c642ae9b75fee120b2d96c712538bd2cf283228d2337df2cf2988e3c02678ef4"
	[ruby]="https://cache.ruby-lang.org/pub/ruby/3.3/ruby-3.3.10.tar.gz b555baa467a306cfc8e6c6ed24d0d27b27e9a1bed1d91d95509859eac6b0e928"
	[dnsmasq]="https://thekelleys.org.uk/dnsmasq/dnsmasq-2.93.tar.xz 0c00d4e5c97c8306e5fb932b348b34269c9c29a0e7df0e8e82958b407092bc19"
	[libmnl]="https://netfilter.org/projects/libmnl/files/libmnl-1.0.5.tar.bz2 274b9b919ef3152bfb3da3a13c950dd60d6e2bcd54230ffeca298d03b40d0525"
	[libnftnl]="https://netfilter.org/projects/libnftnl/files/libnftnl-1.3.1.tar.xz 607da28dba66fbdeccf8ef1395dded9077e8d19f2995f9a4d45a9c2f0bcffba8"
	[nftables]="https://netfilter.org/projects/nftables/files/nftables-1.1.6.tar.xz 372931bda8556b310636a2f9020adc710f9bab66f47efe0ce90bff800ac2530c"
)

die() { echo "错误：$*" >&2; exit 1; }
done_() { [[ -e $STAMP/$1 ]]; }
mark() { touch "$STAMP/$1"; }

check_host() {
	local miss=() c p
	# 依赖的库都从源码编，这里只要编译工具
	for c in gcc make cmake pkg-config git curl bzip2 xz patch perl strip; do
		command -v $c >/dev/null || miss+=("$c")
	done
	((${#miss[@]} == 0)) || die "缺少：${miss[*]}。Debian/Ubuntu：sudo apt install build-essential cmake pkg-config git curl bzip2 xz-utils patch perl"
	[[ $WORK != /mnt/* ]] || die "请在 Linux 文件系统里编译（WORK=$WORK 在 /mnt 下）"
}

fetch() { # fetch <名字>：按锁定的 commit 浅克隆
	local n=$1
	# 稀疏检出的目录列表可能变了，重新设置一下（只是本地检出，不下载）
	if done_ fetch-$n; then
		[[ -z ${SPARSE[$n]-} ]] || git -C "$SRC/$n" sparse-checkout set ${SPARSE[$n]}
		return
	fi
	echo ">>> 下载 $n @ ${REV[$n]:0:12}"
	rm -rf "$SRC/$n" && git init -q "$SRC/$n"
	[[ -z ${SPARSE[$n]-} ]] || git -C "$SRC/$n" sparse-checkout set ${SPARSE[$n]}
	GIT_TERMINAL_PROMPT=0 git -C "$SRC/$n" fetch -q --depth 1 "${URL[$n]}" "${REV[$n]}" </dev/null ||
		die "下载 $n 失败（${URL[$n]}），请检查网络后重试"
	git -C "$SRC/$n" checkout -q FETCH_HEAD
	mark fetch-$n
}

owrt_patches() {
	local n p
	for n in "${!OWRT_PATCHES[@]}"; do
		done_ owrt-patch-$n && continue
		for p in "$SRC/openwrt/${OWRT_PATCHES[$n]}"/*.patch; do
			patch -d "$SRC/$n" -p1 -s -N <"$p" || die "OpenWrt 补丁 ${p##*/} 打不上（$n）"
		done
		mark owrt-patch-$n
	done
}

fetch_tar() { # fetch_tar <名字>：下载源码包、校验 sha256、解到 $SRC/<名字>
	local n=$1 url sum f
	done_ fetch-$n && return
	read -r url sum <<<"${TARBALL[$n]}"
	f=$SRC/${url##*/}
	echo ">>> 下载 ${url##*/}"
	curl -fsSL --retry 3 -o "$f" "$url" || die "下载 $n 失败（$url）"
	echo "$sum  $f" | sha256sum -c --quiet || die "$n 校验和不符"
	rm -rf "$SRC/$n" && mkdir "$SRC/$n" && tar -xf "$f" -C "$SRC/$n" --strip-components=1
	mark fetch-$n
}

# 头文件和库先找暂存目录；运行时库路径写死为 $PREFIX/lib
S=$STAGE$PREFIX
export PKG_CONFIG_PATH=$S/lib/pkgconfig
# .pc 文件里写的是安装路径 /opt/openclash/rt，编译时头文件和库在暂存目录，让 pkg-config 自动加上暂存目录前缀
export PKG_CONFIG_LIBDIR=$S/lib/pkgconfig PKG_CONFIG_SYSROOT_DIR=$STAGE
# glibc 2.42+ 的 strchr 等返回 const 指针，老代码赋给非 const 指针会触发 -Werror；
# gcc 10（Debian 11）对 setjmp 附近的变量会误报 -Wclobbered；
# ucode 的 util.h 用 vasprintf，glibc 2.31 只在 _GNU_SOURCE 下声明它，而各项目对 _GNU_SOURCE 的定义互相冲突，
# 所以强制包含一个只声明 vasprintf 的头文件（原型与 glibc 一致，重复声明无害）
COMPAT_H=$WORK/glibc-compat.h
export CFLAGS="-O2 -I$S/include -include $COMPAT_H -Wno-error=discarded-qualifiers -Wno-clobbered"
export LDFLAGS="-L$S/lib -Wl,-rpath-link,$S/lib"

# CMAKE_POLICY_VERSION_MINIMUM：几个仓库还写着 cmake_minimum_required(2.6/3.0)，CMake 4 默认直接报错
cm() { # cm <名字> <源码目录> [cmake 选项...]
	local n=$1 s=$2; shift 2
	done_ build-$n && return
	echo ">>> 编译 $n"
	# 每次从干净的编译目录开始：上次失败留下的 CMakeCache 会记住错误的路径（jsonpath 在源码目录里编，不能删）
	[[ $s == "$BLD/$n" ]] || rm -rf "$BLD/$n"
	cmake -S "$s" -B "$BLD/$n" -Wno-dev \
		-DCMAKE_BUILD_TYPE=Release \
		-DCMAKE_INSTALL_PREFIX=$PREFIX \
		-DCMAKE_PREFIX_PATH="$S" \
		-DCMAKE_INSTALL_RPATH=$PREFIX/lib \
		-DCMAKE_POLICY_VERSION_MINIMUM=3.5 "$@" >"$BLD/$n.log" 2>&1 ||
		die "$n 配置失败，见 $BLD/$n.log"
	cmake --build "$BLD/$n" -j"$JOBS" >>"$BLD/$n.log" 2>&1 || die "$n 编译失败，见 $BLD/$n.log"
	DESTDIR=$STAGE cmake --install "$BLD/$n" >>"$BLD/$n.log" 2>&1 || die "$n 安装失败，见 $BLD/$n.log"
	mark build-$n
}

ac() { # ac <名字> [configure 选项...]：autoconf 项目（libxcrypt、yaml、ruby）
	local n=$1; shift
	done_ build-$n && return
	echo ">>> 编译 $n"
	rm -rf "$BLD/$n" && cp -a "$SRC/$n" "$BLD/$n"
	# 之前装进暂存目录的 libtool .la 文件记的是安装路径（/opt/openclash/rt/lib），后面的项目链接时按它去找会找不到；
	# 删掉后 libtool 就按 pkg-config 给的 -L/-l 链接
	rm -f "$S"/lib/*.la
	{
		cd "$BLD/$n" &&
		./configure --prefix=$PREFIX --disable-static "LDFLAGS=$LDFLAGS -Wl,-rpath,$PREFIX/lib" "$@" &&
		make -j"$JOBS" && make DESTDIR="$STAGE" install
	} >"$BLD/$n.log" 2>&1 || die "$n 编译失败，见 $BLD/$n.log"
	cd "$HERE"
	mark build-$n
}

# Lua 5.1 用 OpenWrt 的包和补丁（LNUM 整数、共享库 liblua.so、默认搜索路径 /usr/lib/lua），编法照 OpenWrt 的 Makefile
build_lua() {
	done_ build-lua && return
	echo ">>> 编译 Lua 5.1"
	local b=$BLD/lua
	rm -rf "$b" && cp -a "$SRC/lua" "$b"
	{
		# Lua 的 Makefile 把 -llua 写在 lua.o 前面，默认开 --as-needed 的 gcc（Debian/Ubuntu）会把它丢掉
		make -C "$b" "CC=gcc -Wl,--no-as-needed" "CFLAGS=-O2 -fPIC -DLUA_USE_LINUX" "MYLDFLAGS=-Wl,-rpath,$PREFIX/lib" PKG_VERSION=5.1.5 linux &&
		rm -f "$S/lib/liblua.so" && make -C "$b" INSTALL_TOP="$S" install
	} >"$BLD/lua.log" 2>&1 || die "Lua 编译失败，见 $BLD/lua.log"
	# OpenWrt 的 Lua 装出来叫 lua5.1，上游脚本用 lua
	ln -sfn lua5.1 "$S/bin/lua"
	# ubus/uci 的 lua 绑定、LuCI 的 C 模块按 pkg-config 名 lua5.1 找头文件和库
	mkdir -p "$S/lib/pkgconfig"
	printf 'prefix=%s\nName: Lua\nDescription: Lua 5.1 (OpenWrt)\nVersion: 5.1.5\nLibs: -L${prefix}/lib -llua\nCflags: -I${prefix}/include\n' \
		"$PREFIX" >"$S/lib/pkgconfig/lua5.1.pc"
	mark build-lua
}

# 用 Makefile/直接 gcc 编译的 LuCI、ucode C 模块
LUCI_VERSION=git-${REV[luci]:0:7}
LUCI_BRANCH="LuCI openwrt-24.10 branch"
# --no-as-needed：这些 Makefile 把 -lcrypt 等写在目标文件前面，--as-needed 会把它丢掉
RT_LDFLAGS="$LDFLAGS -Wl,-rpath,$PREFIX/lib -Wl,--no-as-needed"

luci_c() {
	done_ build-luci-c && return
	echo ">>> 编译 LuCI 的 C 模块"
	local L=$SRC/luci b=$BLD/luci-c LUA_CFLAGS="-I$S/include"
	rm -rf "$b" && mkdir -p "$b"
	cp -a "$L/modules/luci-base/src" "$b/base"
	cp -a "$L/modules/luci-lua-runtime/src" "$b/rt"
	cp -a "$L/libs/luci-lib-nixio/src" "$b/nixio"
	cp -a "$L/libs/luci-lib-jsonc/src" "$b/jsonc"
	cp -a "$L/libs/luci-lib-ip/src" "$b/ip"
	local mk=(CC=gcc FPIC=-fPIC "CFLAGS=$CFLAGS $LUA_CFLAGS" "LDFLAGS=$RT_LDFLAGS"
		LUCI_VERSION="$LUCI_VERSION" LUCI_GITBRANCH="$LUCI_BRANCH")
	{
		make -C "$b/base" "${mk[@]}" compile po2lmo &&
		make -C "$b/rt" "${mk[@]}" compile &&
		make -C "$b/nixio" "${mk[@]}" compile &&
		make -C "$b/jsonc" "${mk[@]}" JSONC_CFLAGS="-std=gnu99 $(pkg-config --cflags json-c)" compile &&
		make -C "$b/ip" "${mk[@]}" IP_CFLAGS="-std=gnu99 -I$S/include/libnl-tiny" compile &&
		gcc $CFLAGS $LUA_CFLAGS -fPIC -Wall -shared $RT_LDFLAGS -llua \
			-o "$b/lua.so" "$L/contrib/package/ucode-mod-lua/src/lua.c" &&
		gcc $CFLAGS -fPIC -Wall -shared $RT_LDFLAGS -o "$b/html.so" "$L/contrib/package/ucode-mod-html/src/html.c"
	} >"$BLD/luci-c.log" 2>&1 || die "LuCI C 模块编译失败，见 $BLD/luci-c.log"

	install -Dm755 "$b/base/core.so" "$S/lib/ucode/luci/core.so"
	install -Dm755 "$b/lua.so" "$S/lib/ucode/lua.so"
	install -Dm755 "$b/html.so" "$S/lib/ucode/html.so"
	# Lua C 模块放 OpenWrt 原路径 /usr/lib/lua（我们的 Lua 默认就搜这里）
	install -Dm755 "$b/rt/parser.so" "$STAGE/usr/lib/lua/luci/template/parser.so"
	install -Dm755 "$b/nixio/nixio.so" "$STAGE/usr/lib/lua/nixio.so"
	install -Dm755 "$b/jsonc/jsonc.so" "$STAGE/usr/lib/lua/luci/jsonc.so"
	install -Dm755 "$b/ip/ip.so" "$STAGE/usr/lib/lua/luci/ip.so"
	install -Dm644 "$b/base/version.uc" "$STAGE/usr/share/ucode/luci/version.uc"
	install -Dm644 "$b/rt/version.lua" "$STAGE/usr/lib/lua/luci/version.lua"
	mark build-luci-c
}

# LuCI 的脚本、模板、静态文件按 luci.mk 的布局放置，不需要编译
luci_files() {
	done_ build-luci-files && return
	echo ">>> 安装 LuCI 文件"
	local L=$SRC/luci p
	for p in modules/luci-base modules/luci-lua-runtime modules/luci-compat themes/luci-theme-bootstrap \
		libs/luci-lib-base libs/luci-lib-nixio libs/luci-lib-jsonc libs/luci-lib-ip; do
		[[ -d $L/$p/luasrc ]] && mkdir -p "$STAGE/usr/lib/lua/luci" && cp -a "$L/$p/luasrc/." "$STAGE/usr/lib/lua/luci/"
		[[ -d $L/$p/ucode ]] && mkdir -p "$STAGE/usr/share/ucode/luci" && cp -a "$L/$p/ucode/." "$STAGE/usr/share/ucode/luci/"
		[[ -d $L/$p/htdocs ]] && mkdir -p "$STAGE/www" && cp -a "$L/$p/htdocs/." "$STAGE/www/"
		[[ -d $L/$p/root ]] && cp -a "$L/$p/root/." "$STAGE/"
	done
	# luci-mod-status 只取 3 个页面：系统状态（概况里只留系统/内存/存储三块）、系统日志、进程。
	# 菜单由我们的 menu.d/openclash-linux.json 挂到 OpenClash 下；syslog-wrapper 用 files/ 里改调 journalctl 的版本
	local st=$L/modules/luci-mod-status f
	for f in index syslog processes include/10_system include/20_memory include/25_storage; do
		install -Dm644 "$st/htdocs/luci-static/resources/view/status/$f.js" "$STAGE/www/luci-static/resources/view/status/$f.js"
	done
	for f in luci-mod-status luci-mod-status-index; do
		install -Dm644 "$st/root/usr/share/rpcd/acl.d/$f.json" "$STAGE/usr/share/rpcd/acl.d/$f.json"
	done
	install -Dm644 "$st/ucode/template/admin_status/index.ut" "$STAGE/usr/share/ucode/luci/template/admin_status/index.ut"
	# 配置由 install.sh 从 files/ 安装；procd 脚本、uci-defaults、sysupgrade 钩子在普通 Linux 上用不到；
	# 菜单只用我们自己的 openclash-linux.json（没有 LuCI 主界面和 OpenWrt 的状态/系统/网络菜单）
	rm -rf "$STAGE/etc/config" "$STAGE/etc/init.d" "$STAGE/etc/uci-defaults" "$STAGE/lib/upgrade" \
		"$STAGE/usr/share/luci/menu.d/luci-base.json"
	find "$STAGE" -name '*.luadoc' -delete
	# uhttpd 在父进程里加载调度器，模块顶层建的 ubus 连接会被每个请求 fork 出的子进程共用：
	# 并发请求（页面同时拉翻译、菜单等）会互相读走对方的回复而一直挂住。改成每个请求开始时自己连
	local D=$STAGE/usr/share/ucode/luci/dispatcher.uc
	sed -i -e 's|^let ubus = connect();$|let ubus;|' -e 's|^\thttp = _http;$|\thttp = _http;\n\tubus = connect(); /* openclash-linux */|' "$D"
	[[ $(grep -c 'openclash-linux' "$D") == 1 && $(grep -c '^let ubus;$' "$D") == 1 ]] || die "dispatcher.uc 补丁没打上（LuCI 变了？）"
	# 简体中文翻译（第二个是我们菜单里 LuCI 没有的词条）
	mkdir -p "$STAGE/usr/lib/lua/luci/i18n"
	"$BLD/luci-c/base/po2lmo" "$L/modules/luci-base/po/zh_Hans/base.po" "$STAGE/usr/lib/lua/luci/i18n/base.zh-cn.lmo"
	"$BLD/luci-c/base/po2lmo" "$HERE/files/openclash-linux.zh_Hans.po" "$STAGE/usr/lib/lua/luci/i18n/openclash-linux.zh-cn.lmo"
	mark build-luci-files
}

# OpenWrt 的系统脚本和 fw4 放到 OpenWrt 原路径；启动脚本放进视图目录 /opt/openclash/root（见 install.sh）。
# 视图目录用 Fedora 的布局：脚本在 etc/rc.d/init.d，etc/init.d 指向它。这样宿主无论是 Debian（/etc/init.d 是目录）、
# Fedora（只有 /etc/rc.d）还是 RHEL（/etc/init.d → rc.d/init.d），只要遮住其中一两个路径，两条路径都指到同一组脚本
openwrt_files() {
	echo ">>> 安装 OpenWrt 系统脚本、fw4"
	local O=$SRC/openwrt/package V=$STAGE/opt/openclash/root
	mkdir -p "$V/etc/rc.d/init.d" && ln -sfn rc.d/init.d "$V/etc/init.d"
	install -Dm755 "$O/base-files/files/etc/rc.common" "$STAGE/etc/rc.common"
	install -Dm644 "$O/base-files/files/lib/functions.sh" "$STAGE/lib/functions.sh"
	install -Dm644 -t "$STAGE/lib/functions" "$O"/base-files/files/lib/functions/*.sh "$O/system/procd/files/procd.sh"
	install -Dm644 "$O/system/uci/files/lib/config/uci.sh" "$STAGE/lib/config/uci.sh"
	install -Dm644 "$S/share/libubox/jshn.sh" "$STAGE/usr/share/libubox/jshn.sh"
	install -Dm755 "$O/utils/busybox/files/cron" "$V/etc/rc.d/init.d/cron"
	# fw4 的默认配置不用（files/etc/config/firewall 全部放行）；hotplug 在这里不存在
	(cd "$SRC/firewall4/root" && find . -type f ! -path './etc/config/*' ! -path './etc/init.d/*' ! -path './etc/hotplug.d/*' \
		-exec install -Dm644 {} "$STAGE/{}" \;)
	chmod 755 "$STAGE/sbin/fw4"
	install -Dm755 "$SRC/firewall4/root/etc/init.d/firewall" "$V/etc/rc.d/init.d/firewall"
	# dnsmasq 的启动脚本用原版，改三处（都带断言）：
	# 1. OpenWrt 装包时会建 dnsmasq 用户和组，各发行版不一定有 → 降权到哪儿都有的 nobody（组用它的主组）
	# 2. boot 时原版不加 --interface（那时 netifd 还没把接口拉起来，之后靠接口事件 reload）；
	#    我们的开机脚本在网络就绪后才跑，也没有接口事件，boot 直接按 start 处理
	local D=$V/etc/rc.d/init.d/dnsmasq
	install -Dm755 "$O/network/services/dnsmasq/files/dnsmasq.init" "$D"
	sed -i -e 's|^\tchown dnsmasq:dnsmasq /var/run/dnsmasq$|\tchown nobody /var/run/dnsmasq # openclash-linux|' \
		-e 's|^\t\txappend "--user=dnsmasq"$|\t\txappend "--user=nobody" # openclash-linux|' \
		-e '/^\t\txappend "--group=dnsmasq"$/d' \
		-e '/^boot()$/,/^}$/ s|^\tBOOT=1$|\t: # openclash-linux|' "$D"
	[[ $(grep -c 'openclash-linux' "$D") == 3 ]] && ! grep -q -e '--group=dnsmasq' -e 'BOOT=1' "$D" || die "dnsmasq 启动脚本补丁没打上（脚本变了？）"
	install -Dm644 "$O/network/services/dnsmasq/files/rfc6761.conf" "$STAGE/usr/share/dnsmasq/rfc6761.conf"
	# 相当于 rc.common enable（OpenWrt 装包时做）：开机按序号启动 dnsmasq、fw4、cron
	mkdir -p "$V/etc/rc.d" "$STAGE/etc/crontabs"
	ln -sfn ../init.d/dnsmasq "$V/etc/rc.d/S19dnsmasq"
	ln -sfn ../init.d/firewall "$V/etc/rc.d/S19firewall"
	ln -sfn ../init.d/cron "$V/etc/rc.d/S50cron"
}

# dnsmasq：DNS 劫持模式 1（上游默认）用它转发到内核，「大陆绕过例外列表」靠它的 nftset 往 fw4 的集合里加地址。
# 版本和补丁同 OpenWrt 的 dnsmasq-full，但不编 DHCP/TFTP：旁路由盒子上不能冒出第二个 DHCP 服务器
# （即使把路由器的 /etc/config/dhcp 整个拷过来，启动脚本也会按编译特性丢掉 dhcp-* 选项）
build_dnsmasq() {
	done_ build-dnsmasq && return
	echo ">>> 编译 dnsmasq"
	local b=$BLD/dnsmasq
	rm -rf "$b" && cp -a "$SRC/dnsmasq" "$b"
	make -C "$b" -j"$JOBS" CC=gcc "CFLAGS=$CFLAGS" "LDFLAGS=$LDFLAGS -Wl,-rpath,$PREFIX/lib" \
		COPTS="-DHAVE_UBUS -DHAVE_NFTSET -DNO_DHCP -DNO_TFTP -DNO_AUTH -DNO_IPSET -DNO_ID" \
		>"$BLD/dnsmasq.log" 2>&1 || die "dnsmasq 编译失败，见 $BLD/dnsmasq.log"
	install -Dm755 "$b/src/dnsmasq" "$S/sbin/dnsmasq"
	LD_LIBRARY_PATH=$S/lib "$b/src/dnsmasq" --version | grep -q 'Compile time options:.* no-DHCP .* nftset ' || die "dnsmasq 编译特性不对（要 no-DHCP、nftset）"
	mark build-dnsmasq
}

build_busybox() {
	done_ build-busybox && return
	echo ">>> 编译静态 busybox"
	local b=$BLD/busybox
	rm -rf "$b" && cp -a "$SRC/busybox" "$b"
	{
		make -C "$b" defconfig &&
		# tc 与新内核头文件不兼容（CBQ 已删除），后端也不用它；
		# top 的 CPU 列和小数 OpenWrt 都没开，LuCI 进程页按 OpenWrt 的 top 输出格式解析
		sed -i -e 's/^# CONFIG_STATIC is not set/CONFIG_STATIC=y/' -e 's/^CONFIG_TC=y/# CONFIG_TC is not set/' \
			-e 's/^CONFIG_FEATURE_TOP_SMP_PROCESS=y/# CONFIG_FEATURE_TOP_SMP_PROCESS is not set/' \
			-e 's/^CONFIG_FEATURE_TOP_DECIMALS=y/# CONFIG_FEATURE_TOP_DECIMALS is not set/' "$b/.config" &&
		make -C "$b" -j"$JOBS" CFLAGS= LDFLAGS= busybox
	} >"$BLD/busybox.log" 2>&1 || die "busybox 编译失败，见 $BLD/busybox.log"
	install -Dm755 "$b/busybox" "$S/bin/busybox"
	mark build-busybox
}

main() {
	check_host
	mkdir -p "$SRC" "$BLD" "$STAGE" "$STAMP"
	printf '#include <stdarg.h>\nextern int vasprintf(char **__restrict, const char *__restrict, va_list);\n' >"$COMPAT_H"
	local n
	for n in "${!URL[@]}"; do fetch "$n"; done
	for n in "${!TARBALL[@]}"; do fetch_tar "$n"; done
	owrt_patches

	# rpcd 的 ACL、ucode 脚本、exec 插件目录保持 OpenWrt 原路径，上游 ipk 会往这些目录放文件
	if ! done_ patch-rpcd; then
		sed -i -e 's|INSTALL_PREFIX "/share/rpcd|"/usr/share/rpcd|' -e 's|INSTALL_PREFIX "/libexec/rpcd"|"/usr/libexec/rpcd"|' \
			"$SRC/rpcd/include/rpcd/session.h" "$SRC/rpcd/include/rpcd/plugin.h" "$SRC/rpcd/ucode.c"
		mark patch-rpcd
	fi

	# 先编自带的库：后面的组件都链接它们，不用发行版的
	cm json-c "$SRC/json-c" -DBUILD_STATIC_LIBS=OFF -DDISABLE_WERROR=ON -DBUILD_TESTING=OFF -DCMAKE_INSTALL_LIBDIR=lib
	build_lua
	ac libxcrypt --disable-werror
	ac yaml
	# ruby 只给上游的 YAML.rb/uci.rb 用：不要 rubygems（启动快）、不装文档；openssl 等扩展缺依赖会自动跳过
	ac ruby --disable-install-doc --disable-rubygems --with-libyaml-dir="$S" "CPPFLAGS=-I$S/include"
	rm -rf "$S/lib/ruby/gems" "$S/share/ri"

	local LUAP=-DLUAPATH=/usr/lib/lua
	cm libnl-tiny "$SRC/libnl-tiny"
	cm libubox "$SRC/libubox" -DBUILD_LUA=OFF -DBUILD_EXAMPLES=OFF
	cm ubus "$SRC/ubus" -DBUILD_LUA=ON -DBUILD_EXAMPLES=OFF $LUAP
	cm uci "$SRC/uci" -DBUILD_LUA=ON $LUAP
	cm ucode "$SRC/ucode" \
		-DLIB_SEARCH_PATH="$PREFIX/lib/ucode/*.so:/usr/share/ucode/*.uc:./*.so:./*.uc" \
		-DFS_SUPPORT=ON -DMATH_SUPPORT=ON -DUBUS_SUPPORT=ON -DUCI_SUPPORT=ON -DULOOP_SUPPORT=ON \
		-DNL80211_SUPPORT=OFF -DRTNL_SUPPORT=OFF -DZLIB_SUPPORT=OFF -DDIGEST_SUPPORT=OFF -DDIGEST_SUPPORT_EXTENDED=OFF
	cm lucihttp "$SRC/lucihttp" -DBUILD_LUA=ON -DBUILD_UCODE=ON -DBUILD_TESTS=OFF $LUAP
	# jsonpath 只支持在源码目录内编译（lemon 用相对路径）
	done_ build-jsonpath || { rm -rf "$BLD/jsonpath" && cp -a "$SRC/jsonpath" "$BLD/jsonpath"; }
	cm jsonpath "$BLD/jsonpath"
	cm rpcd "$SRC/rpcd" -DFILE_SUPPORT=ON -DUCODE_SUPPORT=ON -DIWINFO_SUPPORT=OFF -DRPCSYS_SUPPORT=OFF
	cm uhttpd "$SRC/uhttpd" -DUBUS_SUPPORT=ON -DUCODE_SUPPORT=ON -DLUA_SUPPORT=OFF -DTLS_SUPPORT=OFF
	# 和 OpenWrt 一样链接成 /www/cgi-bin/cgi-*：LuCI 的 fs.exec_direct（系统日志页）、文件上传下载走这里
	cm cgi-io "$SRC/cgi-io"
	mkdir -p "$STAGE/www/cgi-bin"
	for n in exec upload download; do ln -sfn $PREFIX/sbin/cgi-io "$STAGE/www/cgi-bin/cgi-$n"; done
	# 匿名会话的 ACL（允许 session access/login），OpenWrt 的 rpcd 包也装这个文件；缺了登录页会弹「会话已过期」
	install -Dm644 "$SRC/rpcd/unauthenticated.json" "$STAGE/usr/share/rpcd/acl.d/unauthenticated.json"
	ln -sf jsonpath "$S/bin/jsonfilter"

	# procd 不是 PID 1 时只连 ubus、提供 service/system 对象，正好当 OpenClash 的服务管理器。
	# 但 ubus 的 system reboot 会走到停机流程 kill(-1)（杀掉宿主全部进程），sysupgrade 会在 procd 里 chroot+exec：
	# 两个方法都改成直接返回「不支持」
	if ! done_ patch-procd; then
		grep -q openclash-linux "$SRC/procd/system.c" || sed -i -e 's|^\tprocd_shutdown(RB_AUTOBOOT);$|\treturn UBUS_STATUS_NOT_SUPPORTED; /* openclash-linux */|' \
			-e '/^static int sysupgrade(struct ubus_context/,/^{$/ s|^{$|{\n\treturn UBUS_STATUS_NOT_SUPPORTED; /* openclash-linux */|' \
			"$SRC/procd/system.c"
		[[ $(grep -c 'openclash-linux' "$SRC/procd/system.c") == 2 ]] || die "procd 补丁没打上（system.c 变了？）"
		mark patch-procd
	fi
	# OpenClash 用 group nogroup 跑内核，防火墙规则按 skgid 65534 放过内核自己的流量。Fedora 一类没有 nogroup
	# （65534 叫 nobody），procd 查不到组就按 root 跑，内核的直连流量被送回 TUN 形成回环：查不到 nogroup 时直接用 65534
	local ic=$SRC/procd/service/instance.c
	if ! grep -q 'openclash-linux: nogroup' "$ic"; then
		sed -i '/struct group \*p = getgrnam(group);/,/^\t\t}$/ s|^\t\t}$|\t\t} else if (!strcmp(group, "nogroup")) { /* openclash-linux: nogroup */\n\t\t\tin->group = strdup(group);\n\t\t\tin->gr_gid = 65534;\n\t\t}|' "$ic"
		grep -q 'openclash-linux: nogroup' "$ic" || die "procd nogroup 补丁没打上（service/instance.c 变了？）"
		rm -f "$STAMP/build-procd"
	fi
	cm udebug "$SRC/udebug"
	# DISABLE_INIT 这条路径上游很少编，新 gcc 有两处告警（未用的 perform_halt、null 格式参数），关掉这两个告警。
	# procd 用 strlcpy，glibc 2.38 才有；更老的 glibc（release.sh 用的 Debian 11 是 2.31）给它补一个
	local pf="-Wno-unused-function -Wno-format-overflow" gv
	gv=$(getconf GNU_LIBC_VERSION | awk '{print $2}')
	if [[ $(printf '%s\n' 2.38 "$gv" | sort -V | head -n1) != 2.38 ]]; then
		printf '%s\n' '#include <stddef.h>' \
			'static inline size_t strlcpy(char *d, const char *s, size_t n) {' \
			'	size_t l = 0, i; while (s[l]) l++;' \
			'	if (n) { for (i = 0; i < n - 1 && i < l; i++) d[i] = s[i]; d[i] = 0; }' \
			'	return l;' \
			'}' >"$WORK/strlcpy-compat.h"
		pf="$pf -include $WORK/strlcpy-compat.h"
	fi
	CFLAGS="$CFLAGS $pf" cm procd "$SRC/procd" -DDISABLE_INIT=1 -DJAIL_SUPPORT=OFF -DSECCOMP_SUPPORT=OFF -DUTRACE_SUPPORT=OFF
	cm opkg "$SRC/opkg" -DENABLE_USIGN=OFF -DBUILD_TESTS=OFF

	# dnsmasq 的 nftset 要 libnftables（只要库：系统的 nft 命令照旧用发行版的，装出来的 nft 删掉）
	ac libmnl
	ac libnftnl
	# nftables 1.1.6 有 4 处 case 标签后面直接跟声明，gcc 11 起才接受（Debian 11 是 gcc 10）：标签后补一个空语句
	if ! done_ patch-nftables; then
		sed -i 's/^\(\t*case \(NFTNL_TUNNEL_TYPE\|TUNNEL\)_GENEVE:\)$/\1;/' "$SRC"/nftables/src/{mnl,netlink,rule,json}.c
		[[ $(cat "$SRC"/nftables/src/{mnl,netlink,rule,json}.c | grep -c '_GENEVE:;$') == 4 ]] || die "nftables 补丁没打上（源码变了？）"
		mark patch-nftables
	fi
	ac nftables --with-mini-gmp --without-cli --disable-man-doc --disable-debug
	rm -rf "$S/sbin/nft" "$S/etc/nftables" "$S/share/nftables" "$S/share/doc/nftables"
	build_dnsmasq

	gcc -O2 -Wall -o "$S/sbin/openclash-view" "$HERE/files/openclash-view.c"
	luci_c
	luci_files
	openwrt_files
	build_busybox

	echo ">>> 打包 $OUT"
	# ruby 会装一些脚本形式的命令（irb、erb……），strip 对它们报错，忽略即可
	find "$S/bin" "$S/sbin" "$S/lib" "$STAGE/usr/lib/lua" -type f \( -perm -u+x -o -name '*.so*' \) ! -name '*.sh' \
		-exec strip --strip-unneeded {} + 2>/dev/null || true
	# 头文件、静态库、pkgconfig 只在编译时用
	tar -C "$STAGE" --owner=0 --group=0 --exclude=opt/openclash/rt/include --exclude='*.a' --exclude='*.la' --exclude=pkgconfig \
		-czf "$OUT" opt usr www etc lib sbin
	echo "完成：$OUT"
}

main "$@"
