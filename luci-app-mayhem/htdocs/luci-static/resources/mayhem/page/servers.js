'use strict';
'require baseclass';
'require form';
'require uci';
'require rpc';
'require ui';
'require mayhem.common as mh';
'require mayhem.tunnels as tunnels';
'require mayhem.vpnkey as vpnkey';
'require mayhem.linkedit as linkedit';
'require mayhem.sheet as sheet';

// Server list: servers added by key, subscriptions, tunnels and the options
// of every server (Mux). Keys and subscriptions form one list, like in Happ:
// the dashboard shows it and picks its active server. Keys go into the "link"
// list of the "pool" section of the config.

const callParse = rpc.declare({ object: 'luci.mayhem', method: 'parse_link', params: [ 'links' ], expect: { '': {} } });
const callDashboard = rpc.declare({ object: 'luci.mayhem', method: 'dashboard', expect: { '': {} } });
const callRename = rpc.declare({ object: 'luci.mayhem', method: 'rename_server', params: [ 'section', 'tag', 'link', 'name' ], expect: { '': {} } });
const callImport = rpc.declare({ object: 'luci.mayhem', method: 'awg_import', params: [ 'name', 'conf', 'section', 'pool', 'label' ], expect: { '': {} } });
const callParseOne = rpc.declare({ object: 'luci.mayhem', method: 'parse_link', params: [ 'link' ], expect: { '': {} } });
const callServerEdit = rpc.declare({ object: 'luci.mayhem', method: 'server_edit', params: [ 'section', 'old', 'link' ], expect: { '': {} } });
const callServerRestore = rpc.declare({ object: 'luci.mayhem', method: 'server_restore', params: [ 'subscription', 'name' ], expect: { '': {} } });
const callRenameSub = rpc.declare({ object: 'luci.mayhem', method: 'rename_subscription', params: [ 'name', 'new_name' ], expect: { '': {} } });

// A key, or a server kept as Xray JSON on one line.
const LINK_RE = /^((vless|vmess|trojan|ss|socks5?|https?|hysteria2|hy2|wireguard|wg):\/\/\S+|\{.*\}$)/i;

const PROTOCOLS = {
	vless: 'VLESS', vmess: 'VMess', trojan: 'Trojan', shadowsocks: 'Shadowsocks', socks: 'SOCKS', http: 'HTTP',
	hysteria: 'Hysteria 2', hysteria2: 'Hysteria 2', wireguard: 'WireGuard'
};

const CSS = `
.mh-add textarea { width:100%; font-family:monospace; box-sizing:border-box; }
.mh-add-row { display:flex; flex-wrap:wrap; gap:8px; align-items:center; margin-top:8px; }
.mh-add-row select, .mh-add-row input { width:auto; min-width:180px; }
.mh-keys { width:100%; margin-top:12px; }
.mh-keys td { vertical-align:middle; }
.mh-keys .mh-key-name { max-width:320px; overflow:hidden; text-overflow:ellipsis; white-space:nowrap; }
.mh-keys .mh-key-actions { width:1%; white-space:nowrap; }
.mh-keys .mh-key-actions > div { gap:4px; justify-content:flex-end; }
.mh-keys .mh-key-actions > div > .btn { flex:0 0 auto; margin:0; }
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

return baseclass.extend({
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

	// Servers deleted from a subscription (the provider's names). After a
	// restore the answer of the router is newer than the cached config.
	hiddenOf(sid) {
		if (this.restored && this.restored[sid])
			return this.restored[sid];

		const v = uci.get('mayhem', sid, 'hidden');

		return Array.isArray(v) ? v : (v ? [ v ] : []);
	},

	// The button of a subscription: brings every server deleted from it back.
	// The router answers with what is still deleted (nothing), which is newer
	// than the cached config.
	restoreHidden(sid, ev) {
		const n = this.hiddenOf(sid).length;

		if (!n) {
			ui.addNotification(null, E('p', _('No servers were deleted from this subscription.')), 'info');
			return Promise.resolve();
		}

		return callServerRestore(sid, '').then((r) => {
			if (r.error) {
				ui.addNotification(null, E('p', r.error), 'error');
				return;
			}

			this.restored = this.restored || {};
			this.restored[sid] = r.hidden || [];

			if (ev && ev.target)
				ev.target.textContent = _('Restore deleted servers');

			ui.addNotification(null, E('p', _('Deleted servers restored: %d. Mayhem applies the list now.').format(n)), 'info');
		});
	},

	// A new name for a subscription; its servers stay where they are chosen.
	renameSub(name) {
		const input = E('input', { 'class': 'cbi-input-text', 'value': name, 'style': 'width:100%' });
		const submit = () => {
			const to = input.value.trim();

			if (to === name)
				return ui.hideModal();

			if (!/^[A-Za-z0-9_]+$/.test(to)) {
				ui.addNotification(null, E('p', _('The subscription name may only contain letters, digits and _')), 'error');
				return Promise.resolve();
			}

			return callRenameSub(name, to).then((r) => {
				if (r.error) {
					ui.addNotification(null, E('p', r.error), 'error');
					return;
				}

				ui.hideModal();
				sheet.reload();
			});
		};

		ui.showModal(_('Rename subscription %s').format(name), [
			E('p', _('Latin letters, digits and _. Its servers, the chain of the server list and the chosen server go along.')),
			input,
			E('div', { 'class': 'right', 'style': 'margin-top:1em' }, [
				E('button', { 'class': 'btn', 'click': ui.hideModal }, _('Cancel')), ' ',
				E('button', { 'class': 'btn cbi-button-action', 'click': ui.createHandlerFn(this, submit) }, _('Rename'))
			])
		]);
	},

	// Saves and applies the staged UCI changes like the button at the bottom.
	apply() {
		return this.handleSaveApply(null, '0');
	},

	// AmneziaVPN keys (vpn://) and WireGuard/AmneziaWG configs become tunnel
	// interfaces, servers of the list like the others.
	addTunnels(confs, say) {
		const next = (i, done) => {
			if (i >= confs.length)
				return Promise.resolve(done);

			const c = confs[i];
			const read = c.key ? vpnkey.read(c.key) : Promise.resolve({ conf: c.conf, name: '' });

			return read.then((r) => callImport('', r.conf, false, true, r.name)).then((r) => {
				if (r.error)
					throw new Error(r.error);

				done.push(r.interface);
				return next(i + 1, done);
			});
		};

		say(_('Unpacking the key…'), '');

		return next(0, []).then((names) => sheet.reload().then(() =>
			ui.addNotification(null, E('p', _('Tunnel %s is added to the server list: it shows on the dashboard in a few seconds, when the router has applied it.').format(names.join(', '))), 'info')
		)).catch((e) => say(e.message, 'mh-fail'));
	},

	addKeys(text, say) {
		say = say || ((m, cls) => ui.addNotification(null, E('p', m), cls === 'mh-fail' ? 'error' : 'info'));

		if (text.indexOf('[Interface]') >= 0)
			return this.addTunnels([ { conf: text } ], say);

		const lines = text.split('\n').map((l) => l.trim()).filter((l) => l && l.charAt(0) !== '#');

		if (!lines.length) {
			say(_('Paste a server key first.'), 'mh-fail');
			return Promise.resolve();
		}

		const keys = lines.filter((l) => vpnkey.isKey(l));

		if (keys.length) {
			if (keys.length !== lines.length) {
				say(_('Add vpn:// keys and other keys separately.'), 'mh-fail');
				return Promise.resolve();
			}

			return this.addTunnels(keys.map((k) => ({ key: k })), say);
		}

		const bad = lines.filter((l) => !LINK_RE.test(l));

		if (bad.length) {
			say(_('Not a server key: %s').format(bad[0].slice(0, 60)), 'mh-fail');
			return Promise.resolve();
		}

		return callParse(lines).then((r) => {
			const res = r.results || [];
			const errors = res.map((x, i) => x.ok ? null : '%s: %s'.format(x.name || lines[i].slice(0, 40), x.error || '?')).filter((x) => x);

			if (errors.length) {
				say(_('These keys cannot be added:') + ' ' + errors.join('; '), 'mh-fail');
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

	// A new name for a key: written into the key itself, applied at once.
	renameKey(k) {
		const input = E('input', { 'class': 'cbi-input-text', 'value': (k.info || {}).name || '', 'maxlength': 64, 'style': 'width:100%' });
		const submit = () => {
			const name = input.value.trim();

			if (!name)
				return Promise.resolve();

			return callRename('', '', k.link, name).then((r) => {
				if (r.error) {
					ui.addNotification(null, E('p', r.error), 'error');
					return;
				}

				ui.hideModal();
				sheet.reload();
			});
		};

		ui.showModal(_('Rename the server'), [
			E('p', _('The name is saved in the server key.')),
			input,
			E('div', { 'class': 'right', 'style': 'margin-top:1em' }, [
				E('button', { 'class': 'btn', 'click': ui.hideModal }, _('Cancel')), ' ',
				E('button', { 'class': 'btn cbi-button-action', 'click': ui.createHandlerFn(this, submit) }, _('Rename'))
			])
		]);
	},

	// All parameters of a key, or the server as Xray JSON.
	editKey(k) {
		return callParseOne(k.link).then((r) => {
			linkedit.dialog(k.link, r.outbound, (k.info || {}).name || r.name || '', (link) => {
				if (link === k.link)
					return null;

				return callServerEdit('pool', k.link, link).then((res) => {
					if (res.error)
						return res.error;

					sheet.reload();
					return null;
				});
			});
		});
	},

	renderAdd(section) {
		const text = E('textarea', {
			'class': 'cbi-input-textarea', 'rows': 4,
			'placeholder': 'vless://…\nss://…\nvpn://…'
		});
		const msg = E('div', { 'class': 'mh-small', 'style': 'margin-top:.5em' });
		// A WireGuard/AmneziaWG .conf file: its text goes into the box.
		const file = E('input', { 'type': 'file', 'accept': '.conf,.txt', 'style': 'display:none', 'change': (ev) => {
			const f = ev.target.files[0];

			if (f)
				f.text().then((t) => { text.value = t.trim(); });
		} });
		const say = (m, cls) => {
			msg.className = 'mh-small ' + (cls || 'mh-muted');
			msg.textContent = m;
		};

		const rows = this.keys.map((k) => {
			const i = k.info || {};
			const proto = PROTOCOLS[i.protocol] || (i.protocol || '?');
			const addr = i.address ? (i.port ? '%s:%s'.format(i.address, i.port) : i.address) : '—';

			return E('tr', { 'class': 'tr' }, [
				E('td', { 'class': 'td mh-key-name', 'data-title': _('Server name'), 'title': i.error || i.name || '' }, [
					i.name || '—',
					i.ok === false ? E('div', { 'class': 'mh-fail mh-small' }, '⚠ ' + _('Skipped: %s').format(i.error || '?')) : ''
				]),
				E('td', { 'class': 'td', 'data-title': _('Protocol') }, proto),
				E('td', { 'class': 'td', 'data-title': _('Address') }, addr),
				// The theme lays out the children of an action cell as rows:
				// the buttons go into one row of their own.
				E('td', { 'class': 'td cbi-section-actions mh-key-actions mh-actions' }, E('div', [
					E('button', {
						'class': 'btn cbi-button',
						'click': ui.createHandlerFn(this, 'editKey', k)
					}, _('Edit')),
					E('button', {
						'class': 'btn cbi-button',
						'click': ui.createHandlerFn(this, 'renameKey', k)
					}, _('Rename')),
					E('button', {
						'class': 'btn cbi-button cbi-button-remove',
						'click': ui.createHandlerFn(this, 'removeKey', k)
					}, _('Delete'))
				]))
			]);
		});

		return E('div', { 'class': 'cbi-section mh-add', 'data-tab': section.section, 'data-tab-title': section.title }, [
			E('div', { 'class': 'cbi-section-descr' },
				_('Paste a server key: vless://, vmess://, trojan://, ss://, hysteria2://, socks://, http(s)://, wireguard://, or an AmneziaVPN key (vpn://) or a WireGuard/AmneziaWG config. Several keys go one per line.')),
			text,
			E('div', { 'class': 'mh-add-row' }, [
				E('button', {
					'class': 'btn cbi-button cbi-button-add',
					'click': ui.createHandlerFn(this, () => this.addKeys(text.value, say))
				}, _('Add')),
				E('button', {
					'class': 'btn cbi-button',
					'click': (ev) => { ev.preventDefault(); file.click(); }
				}, _('Open a .conf file…')),
				file
			]),
			msg,
			E('p', { 'class': 'mh-muted mh-small' }, _('Servers go into the server list on the dashboard and are applied at once.')),
			rows.length ? E('table', { 'class': 'table mh-keys mh-rtable' }, [
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
		s.renderSectionAdd = function(extra_class) {
			const el = form.GridSection.prototype.renderSectionAdd.call(this, extra_class);
			const name = el.querySelector('.cbi-section-create-name');

			if (name)
				name.placeholder = _('Enter a name');

			return el;
		};
		// A rename button next to "Edit" (a subscription that is saved already).
		s.renderRowActions = function(section_id) {
			const td = form.GridSection.prototype.renderRowActions.apply(this, arguments);
			const box = td.querySelector('div') || td;

			box.insertBefore(E('button', {
				'class': 'btn cbi-button cbi-button-neutral mh-rename',
				'title': _('Rename'),
				'click': ui.createHandlerFn(self, (ev) => { ev.preventDefault(); return self.renameSub(section_id); })
			}, '✎'), box.firstChild);

			return td;
		};

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

		o = s.taboption('main', form.Value, 'exclude', _('Remove servers by name'),
			_('A regular expression: servers whose names match it are left out of the list, now and after every update. Case does not matter. For example: Россия|LTE|Torrent'));
		o.modalonly = true;
		o.validate = function(section_id, value) {
			if (!value)
				return true;

			try {
				new RegExp(value, 'i');
				return true;
			}
			catch (e) {
				return _('Not a valid regular expression');
			}
		};

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

		o = s.taboption('main', form.Button, '_restore_hidden', ' ',
			_('Servers deleted from the list on the dashboard do not come back when the subscription is updated. This brings them back.'));
		o.modalonly = true;
		o.inputstyle = 'action';
		o.inputtitle = function(sid) {
			const n = self.hiddenOf(sid).length;

			return n ? '%s (%d)'.format(_('Restore deleted servers'), n) : _('Restore deleted servers');
		};
		o.onclick = function(ev, sid) {
			return self.restoreHidden(sid, ev);
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

		o = s.option(form.Value, 'mux_concurrency', _('Mux concurrency (TCP)'));
		o.datatype = 'range(1,1024)';
		o.placeholder = '8';
		o.depends('mux', '1');

		o = s.option(form.Value, 'mux_xudp_concurrency', _('XUDP concurrency'));
		o.datatype = 'range(1,1024)';
		o.placeholder = '16';
		o.depends('mux', '1');

		o = s.option(form.ListValue, 'mux_xudp_udp443', _('XUDP UDP/443 policy'));
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
