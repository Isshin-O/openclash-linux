'use strict';
'require baseclass';
'require ui';

// openclash-linux：替换 luci-theme-bootstrap 的同名文件（页头菜单由它渲染）。
// 改自 LuCI（https://github.com/openwrt/luci）luci-theme-bootstrap 的 menu-bootstrap.js，本文件沿用 LuCI 的 Apache-2.0 许可。
// 不渲染顶层分类（状态/系统/服务/网络）和页脚的模式菜单；
// OpenClash 的子菜单（上游 6 页 + 3 个系统页）始终横排成页签，页头右侧只留「退出」。
const BASE = 'admin/services/openclash';

return baseclass.extend({
	__init__() {
		ui.menu.load().then(L.bind(this.render, this));
	},

	render(tree) {
		// 直接走 children，不用 getChildren：上游 openclash 节点是 alias，getChildren 会换成别名目标（client）的子节点
		let oc = tree;
		for (const name of BASE.split('/'))
			oc = oc?.children?.[name];

		const logout = tree.children?.admin?.children?.logout;

		if (oc?.satisfied)
			this.renderTabMenu(oc, BASE);

		if (logout?.satisfied) {
			const ul = document.querySelector('#topmenu');
			ul.appendChild(E('li', {}, E('a', { 'href': L.url('admin/logout') }, [ _(logout.title) ])));
			ul.style.display = '';
		}
	},

	// 与上游相同：当前页高亮，有下级页签时递归渲染
	renderTabMenu(tree, url, level) {
		const container = document.querySelector('#tabmenu');
		const ul = E('ul', { 'class': 'tabs' });
		const children = ui.menu.getChildren(tree);
		let activeNode = null;

		children.forEach(child => {
			const isActive = (L.env.dispatchpath[3 + (level || 0)] == child.name);
			const className = 'tabmenu-item-%s %s'.format(child.name, isActive ? ' active' : '');

			ul.appendChild(E('li', { 'class': className }, [
				E('a', { 'href': L.url(url, child.name) }, [ _(child.title) ])]));

			if (isActive)
				activeNode = child;
		});

		if (ul.children.length == 0)
			return;

		container.appendChild(ul);
		container.style.display = '';

		if (activeNode)
			this.renderTabMenu(activeNode, url + '/' + activeNode.name, (level || 0) + 1);
	}
});
