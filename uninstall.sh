#!/usr/bin/env bash
# 卸载：先用 opkg 删掉 luci-app-openclash（走上游的 prerm/postrm，会删 /etc/openclash 和 /etc/config/openclash），
# 再停服务，按安装清单删除 install.sh 装的全部文件
set -Eeuo pipefail

RT=/opt/openclash/rt
MANIFEST=$RT/.manifest

die() { echo "错误：$*" >&2; exit 1; }
((EUID == 0)) || die "请用 root 运行（sudo $0）"
[[ -f $MANIFEST ]] || die "找不到安装清单 $MANIFEST，可能没有安装过"

# 关机流程：停 OpenClash、撤掉它的规则
systemctl stop openclash-rc.service 2>/dev/null || true
if grep -q '^Package: luci-app-openclash$' /usr/lib/opkg/status 2>/dev/null; then
	systemctl start openclash-procd.service
	"$RT/sbin/openclash-run" opkg remove luci-app-openclash || echo "警告：opkg remove 失败，继续卸载" >&2
fi

for u in openclash-rc openclash-uhttpd openclash-procd openclash-rpcd openclash-ubusd; do
	systemctl disable --now "$u.service" 2>/dev/null || true
done
# 撤销对宿主防火墙（firewalld/ufw）的放行
[[ -x $RT/sbin/openclash-hostfw ]] && "$RT/sbin/openclash-hostfw" remove
# fw4 没有关机脚本，它建的 table inet fw4（全放行）在这里删掉
nft delete table inet fw4 2>/dev/null || true
rm -f /var/run/fw4.state /var/run/fw4.lock

list=$(grep '^/.' "$MANIFEST")
# 清单里结尾带 / 的是目录，其余是我们装的文件和符号链接（install.sh 生成）。
# 先删文件和符号链接，再从深到浅删空目录；非空目录 rmdir 会跳过，/opt、/usr 这类顶层目录不碰。
# 目录条目绝不当文件删：运行时包里有 /lib、/sbin 这些目录，合并 /usr 的发行版上它们是指向 usr/ 的符号链接，删了系统就起不来。
# 根目录下的条目一律不删（我们不在根目录下直接装文件），旧格式清单（目录不带 /）也因此碰不到 /lib、/sbin
while read -r p; do
	[[ $p == /*/* && $p != */ ]] || continue
	[[ -d $p && ! -L $p ]] || rm -f -- "$p"
done <<<"$list"
sort -r <<<"$list" | while read -r p; do
	p=${p%/}
	if [[ $p == /*/* && -d $p && ! -L $p ]]; then rmdir --ignore-fail-on-non-empty -- "$p"; fi
done
rm -f "$MANIFEST"
# 运行中产生的：opkg 数据库、视图目录（rc.d 里的启动链接）、openclash-boot 生成的 network 配置、crond 的更新标记
rm -rf /usr/lib/opkg /opt/openclash/root /etc/config/network /etc/crontabs/cron.update
rmdir --ignore-fail-on-non-empty /etc/crontabs 2>/dev/null || true
rmdir --ignore-fail-on-non-empty "$RT" /opt/openclash /www /etc/config /etc/systemd/system/openclash-.service.d 2>/dev/null || true

systemctl daemon-reload
echo "已卸载。"
