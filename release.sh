#!/usr/bin/env bash
# 出通用安装包：在 Debian 11 chroot（glibc 2.31）里跑 build.sh、pack-openclash.sh，再打成自解压的
# openclash-linux-<版本>-<arch>.run。目标机只要求 systemd + glibc ≥ 2.31，不用编译、不用装 lua/ruby。
# 用法：bash release.sh [上游 luci-app-openclash 目录]      需要：debootstrap、sudo
set -Eeuo pipefail

HERE=$(cd "$(dirname "$0")" && pwd)
WORK=${WORK:-$HOME/build/openclash-linux}
ROOT=$WORK/chroot-bullseye
OC=$(realpath "${1:-$HERE/../OpenClash/luci-app-openclash}")
ARCH=$(uname -m)

die() { echo "错误：$*" >&2; exit 1; }
trap 'echo "错误：第 $LINENO 行失败：$BASH_COMMAND" >&2' ERR
command -v debootstrap >/dev/null || die "缺少 debootstrap：sudo apt install debootstrap"
g() { git -c safe.directory='*' "$@"; }
top=$(g -C "$OC" rev-parse --show-toplevel) || die "$OC 不在 git 仓库里（pack-openclash.sh 用 git archive 取源码）"
pfx=$(g -C "$OC" rev-parse --show-prefix)

if [[ ! -x $ROOT/usr/bin/cmake ]]; then
	echo ">>> 建 Debian 11 编译环境 $ROOT"
	sudo debootstrap --variant=buildd --include=cmake,pkg-config,git,curl,ca-certificates,xz-utils,bzip2,fakeroot,patch,perl \
		bullseye "$ROOT" http://deb.debian.org/debian
fi

# 源码只读挂进 chroot，编译目录在 chroot 自己的 /build
MOUNTS=()
mnt() { sudo mkdir -p "$ROOT$2"; sudo mount --bind ${3:+-o $3} "$1" "$ROOT$2"; MOUNTS=("$ROOT$2" "${MOUNTS[@]}"); }
umnt() { local m; for m in "${MOUNTS[@]}"; do sudo umount -l "$m"; done; }
trap umnt EXIT
mnt /proc /proc
mnt /dev /dev
mnt "$HERE" /src/openclash-linux ro
mnt "$top" /src/upstream ro
sudo cp /etc/resolv.conf "$ROOT/etc/resolv.conf"
inroot() { sudo chroot "$ROOT" /usr/bin/env -i HOME=/root PATH=/usr/sbin:/usr/bin:/sbin:/bin WORK=/build "$@"; }
inroot bash /src/openclash-linux/build.sh
inroot bash /src/openclash-linux/pack-openclash.sh "/src/upstream/$pfx"

echo ">>> 打包安装文件"
P=$(mktemp -d)
cp -a "$HERE/install.sh" "$HERE/uninstall.sh" "$HERE/files" "$P/"
cp "$ROOT/build/openclash-rt-$ARCH.tar.gz" "$P/"
ipk=$(ls -t "$ROOT"/build/luci-app-openclash_*_all.ipk | head -n1)
cp "$ipk" "$P/"
ver=${ipk##*/luci-app-openclash_}; ver=${ver%_all.ipk}
out=$WORK/openclash-linux-$ver-$ARCH.run
# 自解压头：找到 __PAYLOAD__ 那一行，后面就是 tar.gz
sed "s/@ARCH@/$ARCH/" >"$out" <<'EOF'
#!/bin/sh
# openclash-linux 安装包（OpenWrt 网页栈 + 上游 OpenClash）。
# 用法：sudo sh <本文件> [--listen 地址:端口] [--no-boot]     卸载：sudo /opt/openclash/rt/sbin/openclash-uninstall
# 再次运行新版本的安装包就是升级（配置保留）。
set -e
[ "$(id -u)" = 0 ] || { echo "请用 root 运行：sudo sh $0" >&2; exit 1; }
[ "$(uname -m)" = @ARCH@ ] || { echo "这个安装包是 @ARCH@ 的，本机是 $(uname -m)" >&2; exit 1; }
T=$(mktemp -d)
trap 'rm -rf "$T"' EXIT
n=$(awk '/^__PAYLOAD__$/ {print NR + 1; exit}' "$0")
tail -n +"$n" "$0" | tar -xz -C "$T"
bash "$T/install.sh" --ipk "$(ls "$T"/luci-app-openclash_*_all.ipk)" "$@" "$T"/openclash-rt-*.tar.gz
exit
__PAYLOAD__
EOF
tar -C "$P" --owner=0 --group=0 -cz . >>"$out"
rm -rf "$P"
echo "完成：$out（$(du -h "$out" | cut -f1)）"
