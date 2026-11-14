#!/usr/bin/env bash
# 从上游源码打出 luci-app-openclash 的 ipk，内容和 OpenWrt 编译系统打的一样：
# 用 make 直接执行上游 Makefile 里的 Build/Prepare、Package/install 和维护脚本定义（变量展开与 OpenWrt 相同），
# 维护脚本外壳照抄 OpenWrt include/package-pack.mk，最后交给 OpenWrt 的 scripts/ipkg-build 打包。
# 用法：bash pack-openclash.sh [上游 luci-app-openclash 目录]   （先跑过 build.sh，要用它编出的 po2lmo 和下载的 ipkg-build）
# 产物：$WORK/luci-app-openclash_<版本>_all.ipk
set -Eeuo pipefail

HERE=$(cd "$(dirname "$0")" && pwd)
WORK=${WORK:-$HOME/build/openclash-linux}
SRCDIR=$(realpath "${1:-$HERE/../OpenClash/luci-app-openclash}")
PO2LMO=$WORK/build/luci-c/base
IPKG_BUILD=$WORK/src/openwrt/scripts/ipkg-build

die() { echo "错误：$*" >&2; exit 1; }
[[ -f $SRCDIR/Makefile && -d $SRCDIR/luasrc ]] || die "$SRCDIR 不是 luci-app-openclash 源码目录"
[[ -x $PO2LMO/po2lmo && -f $IPKG_BUILD ]] || die "先运行 build.sh（要用它编出的 po2lmo 和下载的 ipkg-build）"
command -v fakeroot >/dev/null || die "缺少 fakeroot：sudo apt install fakeroot"

T=$(mktemp -d)
trap 'rm -rf "$T"' EXIT
mkdir -p "$T/inc" "$T/build" "$T/pkg/CONTROL" "$T/src"
# 源码是 git 仓库就用 git archive 取一份（文件权限按 git 记录；Windows 盘上读出来全是 777），否则直接复制
g() { git -c safe.directory='*' "$@"; }
if top=$(g -C "$SRCDIR" rev-parse --show-toplevel 2>/dev/null); then
	g -C "$top" archive --format=tar "HEAD:$(g -C "$SRCDIR" rev-parse --show-prefix)" | tar -x -C "$T/src"
else
	cp -a "$SRCDIR/." "$T/src/"
fi
: >"$T/inc/rules.mk"
echo 'BuildPackage=' >"$T/inc/package.mk"
# 上游 Makefile 之后再读这个：只定义 OpenWrt 的几个安装命令和一个 pack 目标
cat >"$T/pack.mk" <<'EOF'
INSTALL_DIR:=install -d -m0755
INSTALL_DATA:=install -m0644
INSTALL_BIN:=install -m0755
CP:=cp -fpR
comma:=,
empty:=
space:=$(empty) $(empty)
P:=Package/$(PKG_NAME)
DEPS:=libc $(patsubst +%,%,$(filter +%,$(subst DEPENDS:=,,$($(P)))))
MAINT:=$(patsubst MAINTAINER:=%,%,$(filter MAINTAINER:=%,$($(P))))
C:=$(IDIR)/CONTROL

pack:
	mkdir -p $(PKG_BUILD_DIR)
	$(Build/Prepare)
	$(call $(P)/install,$(IDIR))
	printf '%s\n' 'Package: $(PKG_NAME)' 'Version: $(PKG_VERSION)' 'Depends: $(subst $(space),$(comma) ,$(strip $(DEPS)))' \
		'SourceName: $(PKG_NAME)' 'Section: luci' 'Maintainer: $(MAINT)' 'Architecture: all' 'Installed-Size: 0' \
		'Description:  $(strip $($(P)/description))' >$(C)/control
	$(if $($(P)/preinst),$(file >$(C)/preinst,$($(P)/preinst)))
	$(if $($(P)/postinst),$(file >$(C)/postinst-pkg,$($(P)/postinst)))
	$(if $($(P)/prerm),$(file >$(C)/prerm-pkg,$($(P)/prerm)))
	$(if $($(P)/postrm),$(file >$(C)/postrm,$($(P)/postrm)))
	$(if $(strip $($(P)/conffiles)),$(file >$(C)/conffiles,$($(P)/conffiles)))
EOF

PATH=$PO2LMO:$PATH make -s -C "$T/src" -f Makefile -f "$T/pack.mk" pack \
	TOPDIR="$T/inc" INCLUDE_DIR="$T/inc" BUILD_DIR="$T/build" IDIR="$T/pkg"

# 维护脚本外壳，照抄 OpenWrt include/package-pack.mk
C=$T/pkg/CONTROL
printf '%s\n' '#!/bin/sh' '[ "${IPKG_NO_SCRIPT}" = "1" ] && exit 0' '[ -s ${IPKG_INSTROOT}/lib/functions.sh ] || exit 0' \
	'. ${IPKG_INSTROOT}/lib/functions.sh' 'default_postinst $0 $@' >"$C/postinst"
printf '%s\n' '#!/bin/sh' '[ -s ${IPKG_INSTROOT}/lib/functions.sh ] || exit 0' \
	'. ${IPKG_INSTROOT}/lib/functions.sh' 'default_prerm $0 $@' >"$C/prerm"
chmod 644 "$C/control"
chmod 755 "$C"/*inst* "$C"/*rm*

fakeroot bash "$IPKG_BUILD" "$T/pkg" "$WORK" >/dev/null
ls "$WORK"/luci-app-openclash_*_all.ipk
