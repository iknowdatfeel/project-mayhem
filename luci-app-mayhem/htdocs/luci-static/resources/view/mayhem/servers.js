'use strict';
'require view';
'require form';
'require uci';
'require rpc';
'require ui';
'require mayhem.common as mh';
'require mayhem.tunnels as tunnels';

// Server list: servers added by key, subscriptions, tunnels and the options
// of every server (Mux). Keys and subscriptions form one list, like in Happ:
// the dashboard shows it and picks its active server. Keys go into the "link"
// list of the "pool" section of the config.

const callParse = rpc.declare({ object: 'luci.mayhem', method: 'parse_link', params: [ 'links' ], expect: { '': {} } });
const callDashboard = rpc.declare({ object: 'luci.mayhem', method: 'dashboard', expect: { '': {} } });

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

// The server list in the config; older configs get one when a key is added.
function ensurePool() {
	if (!uci.get('mayhem', 'pool')) {
		uci.add('mayhem', 'pool', 'pool');
		uci.set('mayhem', 'pool', 'select', 'auto');
	}
}

return view.extend({
	keys: [],		// [{ link, info }]

	load() {
		return Promise.all([
			uci.load('mayhem').then(() => this.loadKeys()),
			tunnels.info(),
			L.resolveDefault(callDashboard(), {})
		]);
	},

	loadKeys() {
		const list = linksOf('pool').map((l) => ({ link: l }));

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

	addKeys(text) {
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

		return callParse(lines).then((r) => {
			const res = r.results || [];
			const errors = res.map((x, i) => x.ok ? null : '%s: %s'.format(x.name || lines[i].slice(0, 40), x.error || '?')).filter((x) => x);

			if (errors.length) {
				ui.addNotification(null, E('div', [ E('p', _('These keys cannot be added:')), E('ul', errors.map((e) => E('li', e))) ]), 'error');
				return;
			}

			ensurePool();

			const have = linksOf('pool');

			uci.set('mayhem', 'pool', 'link', have.concat(lines.filter((l) => have.indexOf(l) < 0)));

			return this.apply();
		});
	},

	removeKey(k) {
		const left = linksOf('pool').filter((l) => l !== k.link);

		if (left.length)
			uci.set('mayhem', 'pool', 'link', left);
		else
			uci.unset('mayhem', 'pool', 'link');

		return this.apply();
	},

	renderAdd(section) {
		const text = E('textarea', {
			'class': 'cbi-input-textarea', 'rows': 4,
			'placeholder': 'vless://…\nss://…'
		});

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
				E('button', {
					'class': 'btn cbi-button cbi-button-add',
					'click': ui.createHandlerFn(this, () => this.addKeys(text.value))
				}, _('Add'))
			]),
			E('p', { 'class': 'mh-muted mh-small' }, _('Servers go into the server list on the dashboard and are applied at once.')),
			rows.length ? E('table', { 'class': 'table mh-keys' }, [
				E('tr', { 'class': 'tr table-titles' }, [
					E('th', { 'class': 'th' }, _('Server name')), E('th', { 'class': 'th' }, _('Protocol')), E('th', { 'class': 'th' }, _('Address')),
					E('th', { 'class': 'th' })
				])
			].concat(rows)) : E('p', { 'class': 'mh-muted' }, _('No servers added by key yet.'))
		]);
	},

	render(data) {
		const info = data[1] || {};
		const dash = data[2] || {};
		const main = (dash.sections || []).find((x) => x.name === dash.default_section);
		const current = main && (main.nodes || []).find((n) => n.tag === main.active);
		const now = current ? current.name : (main && main.name !== 'pool' ? main.name : null);
		const dev = uci.get('mayhem', 'device') || {};
		const self = this;

		const m = new form.Map('mayhem');
		let s, o;

		m.tabbed = true;

		// --- servers by key (the tab shows no options of its own) ---

		s = m.section(form.NamedSection, 'geo', 'geo', _('Add server'));
		s.render = function() {
			return self.renderAdd(this);
		};

		// --- subscriptions ---

		s = m.section(form.GridSection, 'subscription', _('Subscriptions'),
			_('Servers of every enabled subscription go into the server list on the dashboard.'));
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

		o = s.taboption('main', form.Value, 'url', _('URL'),
			_('Any format: a list of keys (plain or base64) or an Xray JSON config. A link to a file page on GitHub works too.'));
		o.rmempty = false;
		o.validate = function(section_id, value) {
			return (/^https?:\/\/\S+$/).test(value || '') ? true : _('Expected an http(s):// address');
		};

		o = s.taboption('main', form.Value, 'update_interval', _('Update every, hours'));
		o.datatype = 'range(1,720)';
		o.default = '12';
		o.rmempty = false;

		o = s.taboption('main', form.Flag, 'via_xray', _('Download through Xray'),
			now ? _('Through the active server, now %s; when that fails, direct.').format(now)
				: _('Through the active server; when that fails, direct.'));
		o.default = '1';
		o.rmempty = false;
		o.modalonly = true;
		o.cfgvalue = function(sid) {
			const v = this.map.data.get('mayhem', sid, 'via_xray');

			return v != null ? v : (this.map.data.get('mayhem', sid, 'update_via') === 'direct' ? '0' : '1');
		};

		o = s.taboption('device', form.Flag, 'send_hwid', _('Send device data'),
			_('Needed by providers that limit the number of devices. The headers match the Happ client.'));
		o.default = '1';
		o.rmempty = false;
		o.modalonly = true;

		DEVICE_FIELDS.forEach((f) => {
			o = s.taboption('device', form.Value, f[0], f[1], f[0] === 'hwid' ? _('Empty: the HWID of the router, %s.').format(dev.hwid || '—') : null);
			o.placeholder = dev[f[0]] || f[2];
			o.modalonly = true;

			if (f[0] !== 'user_agent')
				o.depends('send_hwid', '1');
		});

		o = s.taboption('device', form.Button, '_new_hwid', ' ');
		o.inputtitle = _('Generate a new HWID');
		o.inputstyle = 'action';
		o.modalonly = true;
		o.depends('send_hwid', '1');
		o.onclick = function(ev, section_id) {
			const field = this.section.children.filter((c) => c.option === 'hwid')[0];

			field.getUIElement(section_id).setValue(randomHwid());
		};

		// --- tunnels (the tab shows no options of its own) ---

		s = m.section(form.NamedSection, 'device', 'device', _('Tunnels'));
		s.render = function() {
			return tunnels.render(info, { 'data-tab': this.section, 'data-tab-title': this.title });
		};

		// --- advanced ---

		s = m.section(form.NamedSection, 'settings', 'settings', _('Advanced'));
		s.addremove = false;

		o = s.option(form.Flag, 'mux', _('Mux for VLESS'),
			_('Several connections share one connection to the server. Applies to every VLESS server; with XTLS Vision only UDP is multiplexed.'));

		o = s.option(form.Value, 'mux_concurrency', _('TCP connections per Mux connection'));
		o.datatype = 'range(1,1024)';
		o.placeholder = '8';
		o.depends('mux', '1');

		o = s.option(form.Value, 'mux_xudp_concurrency', _('UDP connections per Mux connection (XUDP)'));
		o.datatype = 'range(1,1024)';
		o.placeholder = '16';
		o.depends('mux', '1');

		o = s.option(form.ListValue, 'mux_xudp_udp443', _('QUIC (UDP 443) with Mux'));
		o.value('reject', _('Drop: browsers fall back to TCP'));
		o.value('allow', _('Send through Mux'));
		o.value('skip', _('Send without Mux'));
		o.default = 'reject';
		o.depends('mux', '1');

		return m.render().then((node) => {
			node.insertBefore(mh.style(), node.firstChild);
			node.insertBefore(E('style', CSS), node.firstChild);

			return node;
		});
	}
});
