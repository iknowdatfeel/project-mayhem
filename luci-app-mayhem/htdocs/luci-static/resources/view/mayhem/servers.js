'use strict';
'require view';
'require form';
'require uci';
'require rpc';
'require ui';
'require mayhem.common as mh';

// Server list: servers added by key, subscriptions, and the device profile
// that subscription requests carry. Keys go into the "link" list of a proxy
// section, the same list the section editor on the Routing page shows.

const callParse = rpc.declare({ object: 'luci.mayhem', method: 'parse_link', params: [ 'links' ], expect: { '': {} } });

const LINK_RE = /^(vless|vmess|trojan|ss|socks5?|https?|hysteria2|hy2|wireguard|wg):\/\/\S+/i;

const PROTOCOLS = {
	vless: 'VLESS', vmess: 'VMess', trojan: 'Trojan', shadowsocks: 'Shadowsocks', socks: 'SOCKS', http: 'HTTP',
	hysteria: 'Hysteria2', hysteria2: 'Hysteria2', wireguard: 'WireGuard'
};

const CSS = `
.mh-add textarea { width:100%; font-family:monospace; box-sizing:border-box; }
.mh-add-row { display:flex; flex-wrap:wrap; gap:8px; align-items:center; margin-top:8px; }
.mh-add-row select, .mh-add-row input { width:auto; min-width:180px; }
.mh-keys { width:100%; margin-top:12px; }
.mh-keys td { vertical-align:middle; }
.mh-keys .mh-key-name { max-width:320px; overflow:hidden; text-overflow:ellipsis; white-space:nowrap; }
`;

function randomHwid() {
	const abc = 'ABCDEFGHIJKLMNOPQRSTUVWXYZabcdefghijklmnopqrstuvwxyz0123456789';
	const buf = new Uint8Array(16);

	window.crypto.getRandomValues(buf);

	return Array.from(buf, (b) => abc[b % abc.length]).join('');
}

const DEVICE_FIELDS = [
	[ 'user_agent', _('Client (User-Agent)'), 'Happ/3.13.0' ],
	[ 'hwid', _('HWID'), '' ],
	[ 'os', _('OS'), 'Android' ],
	[ 'os_version', _('OS version'), '14' ],
	[ 'model', _('Device name'), 'OpenWrt' ],
	[ 'locale', _('Language'), 'ru' ]
];

// Links are one per entry, but an entry may hold several lines.
function linksOf(sid) {
	const out = [];

	L.toArray(uci.get('mayhem', sid, 'link')).forEach((v) => String(v).split('\n').forEach((l) => {
		l = l.trim();

		if (l && l.charAt(0) !== '#')
			out.push(l);
	}));

	return out;
}

// Proxy sections that take servers from links.
function linkSections() {
	return uci.sections('mayhem', 'section').filter((s) =>
		(s.type || 'proxy') === 'proxy' && (s.proxy_type || 'link') === 'link');
}

return view.extend({
	keys: [],		// [{ section, link, info }]

	load() {
		return uci.load('mayhem').then(() => this.loadKeys());
	},

	loadKeys() {
		const list = [];

		linkSections().forEach((s) => linksOf(s['.name']).forEach((l) => list.push({ section: s['.name'], link: l })));

		if (!list.length) {
			this.keys = [];
			return Promise.resolve();
		}

		return L.resolveDefault(callParse(list.map((k) => k.link)), {}).then((r) => {
			const res = r.results || [];

			list.forEach((k, i) => k.info = res[i] || {});
			this.keys = list;
		});
	},

	// Saves and applies the staged UCI changes like the button at the bottom.
	apply() {
		return this.handleSaveApply(null, '0');
	},

	addKeys(text, target, newName) {
		const lines = text.split('\n').map((l) => l.trim()).filter((l) => l && l.charAt(0) !== '#');

		if (!lines.length) {
			ui.addNotification(null, E('p', _('Paste a server key first.')), 'warning');
			return Promise.resolve();
		}

		const bad = lines.filter((l) => !LINK_RE.test(l));

		if (bad.length) {
			ui.addNotification(null, E('p', _('Not a server key: %s').format(bad[0].slice(0, 60))), 'error');
			return Promise.resolve();
		}

		let sid = target;

		if (target === '') {
			if (!/^[A-Za-z0-9_]+$/.test(newName || '')) {
				ui.addNotification(null, E('p', _('The section name may only contain letters, digits and _')), 'error');
				return Promise.resolve();
			}

			if (uci.get('mayhem', newName)) {
				ui.addNotification(null, E('p', _('There is already a section named %s').format(newName)), 'error');
				return Promise.resolve();
			}
		}

		return callParse(lines).then((r) => {
			const res = r.results || [];
			const errors = res.map((x, i) => x.ok ? null : '%s: %s'.format(x.name || lines[i].slice(0, 40), x.error || '?')).filter((x) => x);

			if (errors.length) {
				ui.addNotification(null, E('div', [ E('p', _('These keys cannot be added:')), E('ul', errors.map((e) => E('li', e))) ]), 'error');
				return;
			}

			if (target === '') {
				sid = uci.add('mayhem', 'section', newName);
				uci.set('mayhem', sid, 'enabled', '1');
				uci.set('mayhem', sid, 'type', 'proxy');
				uci.set('mayhem', sid, 'proxy_type', 'link');
				uci.set('mayhem', sid, 'select', 'auto');
			}

			const have = linksOf(sid);

			uci.set('mayhem', sid, 'link', have.concat(lines.filter((l) => have.indexOf(l) < 0)));

			return this.apply();
		});
	},

	removeKey(k) {
		const left = linksOf(k.section).filter((l) => l !== k.link);

		if (left.length)
			uci.set('mayhem', k.section, 'link', left);
		else
			uci.unset('mayhem', k.section, 'link');

		return this.apply();
	},

	renderAdd(section) {
		const text = E('textarea', {
			'class': 'cbi-input-textarea', 'rows': 4,
			'placeholder': 'vless://…\nss://…'
		});
		const sections = linkSections();
		const target = E('select', { 'class': 'cbi-input-select' }, sections.map((s) => E('option', { 'value': s['.name'] }, s['.name']))
			.concat([ E('option', { 'value': '' }, _('New section…')) ]));
		const name = E('input', {
			'class': 'cbi-input-text', 'placeholder': _('Section name'), 'value': sections.length ? '' : 'main',
			'style': sections.length ? 'display:none' : ''
		});

		target.addEventListener('change', () => name.style.display = target.value === '' ? '' : 'none');

		const rows = this.keys.map((k) => {
			const i = k.info || {};
			const proto = PROTOCOLS[i.protocol] || (i.protocol || '?');
			const addr = i.address ? (i.port ? '%s:%s'.format(i.address, i.port) : i.address) : '—';

			return E('tr', { 'class': 'tr' }, [
				E('td', { 'class': 'td mh-key-name', 'title': i.error || i.name || '' }, [
					i.name || '—',
					i.ok === false ? E('div', { 'class': 'mh-fail mh-small' }, '⚠ ' + _('Skipped: %s').format(i.error || '?')) : ''
				]),
				E('td', { 'class': 'td' }, proto),
				E('td', { 'class': 'td' }, addr),
				E('td', { 'class': 'td' }, k.section),
				E('td', { 'class': 'td cbi-section-actions' }, E('button', {
					'class': 'btn cbi-button cbi-button-remove',
					'click': ui.createHandlerFn(this, 'removeKey', k)
				}, _('Delete')))
			]);
		});

		return E('div', { 'class': 'cbi-section mh-add', 'data-tab': section.section, 'data-tab-title': section.title }, [
			E('div', { 'class': 'cbi-section-descr' },
				_('Paste a server key: vless://, vmess://, trojan://, ss://, hysteria2://, socks://, http(s)://, wireguard://. Several keys go one per line.')),
			text,
			E('div', { 'class': 'mh-add-row' }, [
				E('label', _('Section')), target, name,
				E('button', {
					'class': 'btn cbi-button cbi-button-add',
					'click': ui.createHandlerFn(this, () => this.addKeys(text.value, target.value, name.value))
				}, _('Add'))
			]),
			E('p', { 'class': 'mh-muted mh-small' }, _('Servers are added to the chosen proxy section and applied at once.')),
			rows.length ? E('table', { 'class': 'table mh-keys' }, [
				E('tr', { 'class': 'tr table-titles' }, [
					E('th', { 'class': 'th' }, _('Name')), E('th', { 'class': 'th' }, _('Protocol')), E('th', { 'class': 'th' }, _('Address')),
					E('th', { 'class': 'th' }, _('Section')), E('th', { 'class': 'th' })
				])
			].concat(rows)) : E('p', { 'class': 'mh-muted' }, _('No servers added by key yet.'))
		]);
	},

	render() {
		const proxies = uci.sections('mayhem', 'section')
			.filter((s) => (s.type || 'proxy') === 'proxy')
			.map((s) => s['.name']);
		const dev = uci.get('mayhem', 'device') || {};
		const self = this;

		const m = new form.Map('mayhem');
		let s, o;

		m.tabbed = true;

		// --- servers by key ---

		s = m.section(form.NamedSection, 'settings', 'settings', _('Add server'));
		s.render = function() {
			return self.renderAdd(this);
		};

		// --- subscriptions ---

		s = m.section(form.GridSection, 'subscription', _('Subscriptions'),
			_('Subscription servers are added to sections on the Routing page. Downloads repeat by the interval the provider sets, or every 12 hours.'));
		s.addremove = true;
		s.anonymous = false;
		s.sortable = true;
		s.nodescriptions = true;
		s.addbtntitle = _('Add subscription');
		s.modaltitle = (section_id) => _('Subscription') + ' » ' + section_id;

		s.tab('main', _('Subscription'));
		s.tab('device', _('Device data'));

		o = s.taboption('main', form.Flag, 'enabled', _('Enabled'));
		o.default = '1';
		o.editable = true;
		o.rmempty = false;

		o = s.taboption('main', form.Value, 'url', _('URL'));
		o.rmempty = false;
		o.validate = function(section_id, value) {
			return (/^https?:\/\/\S+$/).test(value || '') ? true : _('Expected an http(s):// address');
		};

		o = s.taboption('main', form.ListValue, 'format', _('Format'));
		o.value('auto', _('Detect'));
		o.value('uri', _('List of links (plain or base64)'));
		o.value('xray_json', _('Xray JSON'));
		o.default = 'auto';
		o.modalonly = true;

		o = s.taboption('main', form.Value, 'update_interval', _('Update every, hours'),
			_('Empty: as the provider says, otherwise 12 hours.'));
		o.datatype = 'range(1,720)';
		o.placeholder = _('Auto');

		o = s.taboption('main', form.ListValue, 'update_via', _('Download'),
			_('If the subscription server is blocked, it can be downloaded through a section.'));
		o.value('auto', _('Direct, then through a section if that fails'));
		o.value('direct', _('Direct only'));
		o.value('section', _('Through a section only'));
		o.default = 'auto';
		o.modalonly = true;

		o = s.taboption('main', form.ListValue, 'update_section', _('Section for downloading'));
		o.value('', _('The first section that uses this subscription'));
		proxies.forEach((n) => o.value(n));
		o.depends('update_via', 'auto');
		o.depends('update_via', 'section');
		o.modalonly = true;

		o = s.taboption('main', form.DynamicList, 'header', _('Extra headers'),
			_('In the form "Name: value".'));
		o.modalonly = true;
		o.validate = function(section_id, value) {
			return (!value || /^[A-Za-z0-9-]+:\s*\S/.test(value)) ? true : _('Expected "Name: value"');
		};

		o = s.taboption('device', form.Flag, 'send_hwid', _('Send device data'),
			_('Needed by providers that limit the number of devices.'));
		o.default = '1';
		o.rmempty = false;
		o.modalonly = true;

		DEVICE_FIELDS.forEach((f) => {
			o = s.taboption('device', form.Value, f[0], f[1], _('Empty: from the device profile.'));
			o.placeholder = dev[f[0]] || f[2];
			o.modalonly = true;

			if (f[0] !== 'user_agent')
				o.depends('send_hwid', '1');
		});

		// --- device profile ---

		s = m.section(form.NamedSection, 'device', 'device', _('Device profile generator'),
			_('How the router presents itself to subscription servers. The headers match the Happ client: x-hwid, x-device-os, x-ver-os, x-device-model, x-device-locale.'));
		s.addremove = false;

		DEVICE_FIELDS.forEach((f) => {
			o = s.option(form.Value, f[0], f[1]);
			o.placeholder = f[2];
		});

		o = s.option(form.Button, '_new_hwid', ' ');
		o.inputtitle = _('Generate a new HWID');
		o.inputstyle = 'action';
		o.onclick = function(ev, section_id) {
			const field = this.section.children.filter((c) => c.option === 'hwid')[0];

			field.getUIElement(section_id).setValue(randomHwid());
		};

		return m.render().then((node) => {
			node.insertBefore(mh.style(), node.firstChild);
			node.insertBefore(E('style', CSS), node.firstChild);

			return node;
		});
	}
});
