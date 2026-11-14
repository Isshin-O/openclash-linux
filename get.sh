#!/bin/sh
# openclash-linux 一键安装：从 GitHub Releases 下载最新的安装包，校验 sha256 后运行。
#   curl -fsSL https://github.com/Isshin-O/openclash-linux/releases/latest/download/get.sh | sudo sh
#   安装参数接在后面：... | sudo sh -s -- --listen 0.0.0.0:8080
#   国内直连 GitHub 不通：... | sudo OC_MIRROR=https://gh-proxy.com/ sh   （下载地址前加这个前缀）
#   只下载、校验，不安装：... | sh -s -- --download-only   （安装包存到当前目录）
set -eu
REPO=Isshin-O/openclash-linux
BASE=${OC_MIRROR:-}https://github.com/$REPO/releases/latest/download
arch=$(uname -m)
die() { echo "错误：$*" >&2; exit 1; }

[ "$arch" = x86_64 ] || die "目前只有 x86_64 的安装包，本机是 $arch"
command -v curl >/dev/null || die "需要 curl"
command -v sha256sum >/dev/null || die "需要 sha256sum（coreutils）"
only=0
[ "${1-}" = --download-only ] && { only=1; shift; }
[ $only = 1 ] || [ "$(id -u)" = 0 ] || die "请用 root 运行：curl -fsSL ... | sudo sh"

T=$(mktemp -d)
trap 'rm -rf "$T"' EXIT
echo ">>> 下载 $BASE/SHA256SUMS"
curl -fL --retry 3 -o "$T/SHA256SUMS" "$BASE/SHA256SUMS" || die "下载失败；国内网络可设 OC_MIRROR=https://gh-proxy.com/ 再试"
name=$(awk -v a="$arch" '$2 ~ "^openclash-linux-.*-" a "\\.run$" {print $2; exit}' "$T/SHA256SUMS")
[ -n "$name" ] || die "发布里没有 $arch 的安装包"
echo ">>> 下载 $name"
curl -fL --retry 3 -o "$T/$name" "$BASE/$name" || die "下载失败；国内网络可设 OC_MIRROR=https://gh-proxy.com/ 再试"
(cd "$T" && grep " $name\$" SHA256SUMS | sha256sum -c -) || die "sha256 校验不通过，安装包可能损坏或被篡改"

if [ $only = 1 ]; then
	cp "$T/$name" .
	echo "已保存 ./$name，安装：sudo sh ./$name"
	exit 0
fi
sh "$T/$name" "$@"
