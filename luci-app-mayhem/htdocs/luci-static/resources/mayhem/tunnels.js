'use strict';
'require baseclass';
'require rpc';
'require ui';
'require dom';
'require poll';
'require uci';
'require mayhem.vpnkey as vpnkey';
'require mayhem.sheet as sheet';

// Tunnels: network interfaces (AmneziaWG, WireGuard and others) that tunnel
// sections and proxy sections use. Lists them, imports configs and keys,
// installs AmneziaWG and dnsmasq-full.

const callTunnelInfo = rpc.declare({ object: 'luci.mayhem', method: 'tunnel_info', expect: { '': {} } });
const callInstall = rpc.declare({ object: 'luci.mayhem', method: 'system_install', params: [ 'what', 'version' ], expect: { '': {} } });
const callImport = rpc.declare({ object: 'luci.mayhem', method: 'awg_import', params: [ 'name', 'conf', 'section', 'pool', 'label' ], expect: { '': {} } });
const callRename = rpc.declare({ object: 'luci.mayhem', method: 'rename_interface', params: [ 'from', 'to' ], expect: { '': {} } });
const callTunnelGet = rpc.declare({ object: 'luci.mayhem', method: 'tunnel_get', params: [ 'iface' ], expect: { '': {} } });
const callTunnelDelete = rpc.declare({ object: 'luci.mayhem', method: 'tunnel_delete', params: [ 'iface', 'mode' ], expect: { '': {} } });
const callTunnelSet = rpc.declare({ object: 'luci.mayhem', method: 'tunnel_set', params: [ 'iface', 'conf', 'obfs', 'obfs_port', 'obfs_key', 'obfs_masking' ], expect: { '': {} } });

const IFACE_RE = /^[a-z][a-z0-9_]{0,14}$/;

const TUNNEL_PROTOS = [ 'amneziawg', 'wireguard', 'openvpn', 'openconnect', 'vpnc', 'l2tp', 'pptp' ];

const NAMES = {
	amneziawg: 'AmneziaWG', wireguard: 'WireGuard', openvpn: 'OpenVPN', openconnect: 'OpenConnect',
	vpnc: 'VPNC', l2tp: 'L2TP', pptp: 'PPTP'
};

const TITLES = {
	awg: _('Installing AmneziaWG'),
	protos: _('Restarting the network'),
	dnsmasq: _('Installing dnsmasq-full'),
	xray: _('Updating Xray'),
	mayhem: _('Updating Mayhem'),
	phobos: _('Installing wg-obfuscator'),
	faketcp: _('Installing phantun')
};

// WireGuard obfuscators: [ value, title, binary, what the server runs ].
const OBFS = [
	[ 'none', _('None'), null, null ],
	[ 'phobos', _('Phobos (wg-obfuscator)'), 'wg-obfuscator', _('wg-obfuscator with the same key in front of WireGuard') ],
	[ 'faketcp', _('Fake TCP (phantun)'), 'phantun', _('phantun_server in front of WireGuard') ]
];

return baseclass.extend({
	info() {
		return L.resolveDefault(callTunnelInfo(), {});
	},

	// Runs an installation in the background and shows its log until it ends.
	// A button passes its click event after the arguments: only a string is a
	// version (rpcd turns the call down when the type is wrong).
	install(what, version) {
		return callInstall(what, typeof version === 'string' ? version : '').then((r) => {
			if (r.error || r.busy) {
				ui.addNotification(null, E('p', r.error || _('An installation is already running')), 'error');
				return;
			}

			const log = E('pre', { 'style': 'max-height:20em;overflow:auto;white-space:pre-wrap' }, _('Starting…'));

			ui.showModal(TITLES[what] || _('Installation'), [
				E('p', _('This takes a minute. Do not close the page.')), log
			]);

			let waits = 0;

			// The installer starts a moment later, and it may restart the
			// network or dnsmasq on its way (a call fails then): it is done only
			// when it wrote its exit code.
			// One check at a time: rpcd answers calls one by one.
			let checking = false;
			const check = () => checking ? Promise.resolve() : (checking = true, callTunnelInfo().then((t) => {
				const inst = t.install || {};

				if (inst.log)
					log.textContent = inst.log;

				if (inst.running || (inst.rc == null && ++waits < 20))
					return;

				poll.remove(check);
				waits = 0;
				ui.showModal(null, [
					log,
					E('p', inst.rc === '0' ? _('Done.') : inst.rc == null ? _('The installer stopped without a result, see the log above.')
						: _('Failed, see the log above. Nothing else was changed.')),
					E('div', { 'class': 'right' }, E('button', { 'class': 'btn', 'click': () => { ui.hideModal(); sheet.reload(); } }, _('Close')))
				]);
			}).catch(() => {}).finally(() => { checking = false; }));

			poll.add(check, 3);
		});
	},

	// done(result): after an import; without it the open window is drawn
	// again.
	importDialog(info, done) {
		const name = E('input', { 'class': 'cbi-input-text', 'value': 'awg0', 'maxlength': 15 });
		const text = E('textarea', {
			'class': 'cbi-input-textarea', 'rows': 10, 'style': 'width:100%;font-family:monospace',
			'placeholder': '[Interface]\nPrivateKey = …\n\nvpn://…'
		});
		const file = E('input', { 'type': 'file', 'accept': '.conf,.txt' });
		const label = E('input', { 'class': 'cbi-input-text', 'placeholder': _('For example, Netherlands') });
		const section = E('input', { 'type': 'checkbox' });

		file.addEventListener('change', () => {
			const f = file.files[0];

			if (f)
				f.text().then((t) => text.value = t);
		});

		const submit = () => {
			const raw = text.value.trim();

			if (!IFACE_RE.test(name.value)) {
				ui.addNotification(null, E('p', _('The interface name must start with a letter: up to 15 lower-case letters, digits and _')), 'error');
				return Promise.resolve();
			}

			const conf = vpnkey.isKey(raw) ? vpnkey.decode(raw) : Promise.resolve(raw);

			return conf.then((c) => callImport(name.value, c, section.checked, true, label.value.trim())).then((r) => {
				if (r.error) {
					ui.addNotification(null, E('p', r.error), 'error');
					return;
				}

				ui.hideModal();
				ui.addNotification(null, E('p', r.section
					? _('Interface %s and section %s are created. Add rules to the section in Routing.').format(r.interface, r.section)
					: r.pool ? _('Interface %s is created and added to the server list: choose it on the dashboard.').format(r.interface)
					: _('Interface %s is created.').format(r.interface)), 'info');

				if (done)
					done(r);
				else
					sheet.reload();
			}).catch((e) => ui.addNotification(null, E('p', e.message), 'error'));
		};

		ui.showModal(_('Import a tunnel'), [
			E('p', _('Paste a WireGuard or AmneziaWG config (.conf) or an AmneziaVPN key (vpn://), or pick a .conf file. The tunnel is created without a default route: only traffic of Mayhem sections goes into it.')),
			info.awg ? '' : E('p', { 'class': 'mh-warn' }, _('AmneziaWG is not installed: only plain WireGuard configs can be imported.')),
			E('div', { 'class': 'cbi-value' }, [ E('label', { 'class': 'cbi-value-title' }, _('Interface name')), E('div', { 'class': 'cbi-value-field' }, name) ]),
			E('div', { 'class': 'cbi-value' }, [ E('label', { 'class': 'cbi-value-title' }, _('Config or key')), E('div', { 'class': 'cbi-value-field' }, [ text, E('br'), file ]) ]),
			E('div', { 'class': 'cbi-value' }, [ E('label', { 'class': 'cbi-value-title' }, _('Tunnel name')), E('div', { 'class': 'cbi-value-field' }, label) ]),
			E('div', { 'class': 'cbi-value' }, [ E('label', { 'class': 'cbi-value-title' }, _('Create a routing section')), E('div', { 'class': 'cbi-value-field' }, [ section, ' ',
				E('span', { 'class': 'mh-muted' }, _('Only to route chosen sites into this tunnel; to use it for all traffic, choose it on the dashboard instead.')) ]) ]),
			E('div', { 'class': 'right' }, [
				E('button', { 'class': 'btn', 'click': ui.hideModal }, _('Cancel')), ' ',
				E('button', { 'class': 'btn cbi-button-action', 'click': ui.createHandlerFn(this, submit) }, _('Import'))
			])
		]);
	},

	// The tunnel as its .conf text, like a server as its Xray JSON. Saved
	// over the same interface; it reconnects. done() runs after a save.
	editDialog(iface, done) {
		return callTunnelGet(iface).then((r) => {
			if (r.error) {
				ui.addNotification(null, E('p', r.error), 'error');
				return;
			}

			const msg = E('div', { 'class': 'mh-small' });
			const text = E('textarea', {
				'class': 'cbi-input-textarea', 'rows': 18, 'spellcheck': 'false',
				'style': 'width:100%;font-family:monospace;font-size:90%;box-sizing:border-box'
			}, r.conf);
			const ob = r.obfs || {};
			const installed = r.installed || {};
			const field = (title, widget, note) => E('div', { 'class': 'cbi-value' }, [
				E('label', { 'class': 'cbi-value-title' }, title),
				E('div', { 'class': 'cbi-value-field' }, [ widget, note ? E('div', { 'class': 'cbi-value-description' }, note) : '' ])
			]);
			const kind = E('select', { 'class': 'cbi-input-select' },
				OBFS.map((o) => E('option', { 'value': o[0], 'selected': (ob.kind || 'none') === o[0] ? '' : null }, o[1])));
			const port = E('input', { 'class': 'cbi-input-text', 'type': 'number', 'min': 1, 'max': 65535, 'value': ob.port || '', 'placeholder': '13255' });
			const key = E('input', { 'class': 'cbi-input-text', 'type': 'password', 'value': ob.key || '', 'autocomplete': 'new-password' });
			const masking = E('select', { 'class': 'cbi-input-select' }, [ 'AUTO', 'STUN', 'NONE' ].map((m) =>
				E('option', { 'value': m, 'selected': (ob.masking || 'AUTO') === m ? '' : null }, m)));
			const missing = E('div', { 'class': 'mh-note mh-small' });
			const rowPort = field(_('Obfuscator server port'), port);
			const rowKey = field(_('Obfuscation key'), key, _('The same key as in the server\'s wg-obfuscator.'));
			const rowMask = field(_('Masking'), masking, _('AUTO and STUN dress the packets as STUN; NONE leaves them as they are.'));
			const note = E('div', { 'class': 'cbi-value-description', 'style': 'margin:0 0 1em' });

			const sync = () => {
				const o = OBFS.find((x) => x[0] === kind.value);
				const on = kind.value !== 'none';

				rowPort.style.display = on ? '' : 'none';
				rowKey.style.display = rowMask.style.display = kind.value === 'phobos' ? '' : 'none';
				note.textContent = on ? _('The tunnel sends its UDP to the obfuscator on the router, which carries it to the endpoint of the .conf on this port; the server runs %s. Fake TCP lowers the MTU to 1428.').format(o[3]) : '';

				dom.content(missing, (on && !installed[kind.value]) ? [
					E('span', { 'class': 'mh-warn' }, _('%s is not installed on the router.').format(o[2])),
					E('button', { 'class': 'btn cbi-button-action', 'click': ui.createHandlerFn(this, () => this.install(kind.value)) }, _('Install'))
				] : []);
			};

			kind.addEventListener('change', sync);

			ui.showModal(_('Edit tunnel %s').format(iface), [
				E('p', { 'class': 'mh-muted mh-small' }, _('Saved over interface %s: its name, firewall zone and Mayhem settings stay. The tunnel reconnects.').format(iface)),
				text,
				E('h5', { 'style': 'margin-top:1em' }, _('Obfuscation')),
				field(_('Obfuscator'), kind),
				note,
				rowPort, rowKey, rowMask,
				missing,
				msg,
				E('div', { 'class': 'right', 'style': 'margin-top:1em' }, [
					E('button', { 'class': 'btn', 'click': ui.hideModal }, _('Cancel')), ' ',
					E('button', { 'class': 'btn cbi-button-action', 'click': ui.createHandlerFn(this, () => {
						const k = kind.value;
						const p = parseInt(port.value, 10) || 0;
						const same = text.value.trim() === String(r.conf).trim() && k === (ob.kind || 'none') &&
							(k === 'none' || (p === ob.port && (k !== 'phobos' || (key.value === ob.key && masking.value === (ob.masking || 'AUTO')))));

						if (same) {
							ui.hideModal();
							return;
						}

						if (k !== 'none' && (p < 1 || p > 65535)) {
							msg.className = 'mh-small mh-fail';
							msg.textContent = _('The obfuscator server port is a number from 1 to 65535');
							return;
						}

						return callTunnelSet(iface, text.value, k, p, key.value, masking.value).then((res) => {
							if (res.error) {
								msg.className = 'mh-small mh-fail';
								msg.textContent = res.error;
								return;
							}

							ui.hideModal();
							ui.addNotification(null, E('p', _('Tunnel %s is saved and reconnects.').format(iface)), 'info');

							if (done)
								done();
						});
					}) }, _('Save'))
				])
			]);

			sync();
			text.focus();
		});
	},

	// A tunnel out of Mayhem: out of the server list only, or with its
	// network interface, peers and tunnel sections.
	// done(mode) runs after it; without it the open window is drawn again.
	deleteDialog(iface, hidden, done) {
		const run = (mode) => callTunnelDelete(iface, mode).then((r) => {
			if (r.error) {
				ui.addNotification(null, E('p', r.error), 'error');
				return;
			}

			ui.hideModal();
			ui.addNotification(null, E('p', mode === 'full' ? _('Tunnel %s is deleted.').format(iface)
				: mode === 'hide' ? _('Tunnel %s is no longer a server.').format(iface) : _('Tunnel %s is a server again.').format(iface)), 'info');

			if (done)
				done(mode);
			else
				sheet.reload();
		});

		ui.showModal(_('Tunnel %s').format(iface), [
			E('p', _('Out of the server list: the tunnel stays a network interface, Mayhem no longer uses it as a server. Delete: the interface, its peers and the tunnel sections that use it go as well; the network restarts.')),
			E('div', { 'class': 'right' }, [
				E('button', { 'class': 'btn', 'click': ui.hideModal }, _('Cancel')), ' ',
				hidden
					? E('button', { 'class': 'btn cbi-button-action', 'click': ui.createHandlerFn(this, () => run('show')) }, _('Back to the server list'))
					: E('button', { 'class': 'btn cbi-button-action', 'click': ui.createHandlerFn(this, () => run('hide')) }, _('Out of the server list')),
				' ',
				E('button', { 'class': 'btn cbi-button-negative', 'click': ui.createHandlerFn(this, () => run('full')) }, _('Delete the tunnel'))
			])
		]);
	},

	// A new name for the network interface: the network, the firewall zone and
	// Mayhem's references change together, the network reloads.
	renameDialog(iface) {
		const input = E('input', { 'class': 'cbi-input-text', 'value': iface, 'maxlength': 15 });
		const submit = () => {
			const to = input.value.trim();

			if (!IFACE_RE.test(to)) {
				ui.addNotification(null, E('p', _('The interface name must start with a letter: up to 15 lower-case letters, digits and _')), 'error');
				return Promise.resolve();
			}

			return callRename(iface, to).then((r) => {
				if (r.error) {
					ui.addNotification(null, E('p', r.error), 'error');
					return;
				}

				ui.hideModal();
				return sheet.reload().then(() =>
					ui.addNotification(null, E('p', _('Interface %s is now %s. The tunnel reconnects.').format(iface, to)), 'info'));
			});
		};

		ui.showModal(_('Rename the interface %s').format(iface), [
			E('p', _('The network interface, its firewall zone and every Mayhem setting that names it are renamed. The tunnel reconnects.')),
			E('div', { 'class': 'cbi-value' }, [ E('label', { 'class': 'cbi-value-title' }, _('Interface name')), E('div', { 'class': 'cbi-value-field' }, input) ]),
			E('div', { 'class': 'right' }, [
				E('button', { 'class': 'btn', 'click': ui.hideModal }, _('Cancel')), ' ',
				E('button', { 'class': 'btn cbi-button-action', 'click': ui.createHandlerFn(this, submit) }, _('Rename'))
			])
		]);
	},

	// The "Tunnels" tab: tunnel interfaces with their state and the sections
	// that use them, import and installation buttons.
	render(info, attrs) {
		const sections = uci.sections('mayhem', 'section');
		const usedBy = (iface) => sections.filter((s) =>
			(s.type === 'interface' && s.interface === iface) || L.toArray(s.iface_node).indexOf(iface) >= 0).map((s) => s['.name']);
		const tunnels = (info.interfaces || []).filter((i) => TUNNEL_PROTOS.indexOf(i.proto) >= 0);
		const kernel = sections.some((x) => x.type === 'interface' && x.enabled !== '0' && (x.route_mode || 'kernel') === 'kernel');
		const notes = [];

		if (!info.awg)
			notes.push(E('p', { 'class': 'mh-note' }, [
				E('span', _('AmneziaWG is not installed.')),
				E('button', { 'class': 'btn cbi-button', 'click': ui.createHandlerFn(this, 'install', 'awg') }, _('Install AmneziaWG'))
			]));

		if ((info.protos_missing || []).length)
			notes.push(E('p', { 'class': 'mh-note mh-warn' }, [
				E('span', _('%s is installed, but the network has not loaded it yet: its tunnels do not start.').format(
					info.protos_missing.map((p) => NAMES[p] || p).join(', '))),
				E('button', { 'class': 'btn cbi-button', 'click': ui.createHandlerFn(this, 'install', 'protos') }, _('Restart the network'))
			]));

		if (info.nftset === false)
			notes.push(E('p', { 'class': 'mh-note' + (kernel ? ' mh-warn' : '') }, [
				E('span', kernel ? _('Tunnel sections in kernel mode need dnsmasq-full: until it is installed, their domains go through Xray.')
					: _('dnsmasq-full is needed only for tunnel sections in kernel mode; tunnels in the server list work without it.')),
				E('button', { 'class': 'btn cbi-button', 'click': ui.createHandlerFn(this, 'install', 'dnsmasq') }, _('Install dnsmasq-full'))
			]));

		// The name shown on the dashboard and in the server list; saved with
		// the page.
		const labelBox = (iface) => E('input', {
			'class': 'cbi-input-text', 'style': 'width:12em',
			'placeholder': iface,
			'value': uci.get('mayhem', iface, 'label') || '',
			'change': (ev) => {
				const v = ev.target.value.trim();

				if (!uci.get('mayhem', iface))
					uci.add('mayhem', 'tunnel', iface);

				uci.set('mayhem', iface, 'label', v || null);
			}
		});

		// The buttons of a tunnel sit together at the end of its row, in one
		// line (the theme would put the children of an action cell under one
		// another); each cell names its column for the narrow layout.
		const rows = tunnels.map((t) => {
			const hidden = uci.get('mayhem', t.name, 'server') === '0';
			const editable = t.proto === 'amneziawg' || t.proto === 'wireguard';

			return E('tr', { 'class': 'tr' }, [
				E('td', { 'class': 'td', 'data-title': _('Tunnel name') }, labelBox(t.name)),
				E('td', { 'class': 'td', 'data-title': _('Interface') }, E('b', t.name)),
				E('td', { 'class': 'td', 'data-title': _('Protocol') }, NAMES[t.proto] || t.proto),
				E('td', { 'class': 'td', 'data-title': _('State') },
					t.up ? E('span', { 'class': 'mh-ok' }, '✔ ' + _('Works')) : E('span', { 'class': 'mh-fail' }, '✘ ' + _('Does not work'))),
				E('td', { 'class': 'td', 'data-title': _('Sections') }, [
					usedBy(t.name).join(', ') || E('span', { 'class': 'mh-muted' }, _('Not used')),
					hidden ? E('div', { 'class': 'mh-muted mh-small' }, _('Not in the server list')) : ''
				]),
				E('td', { 'class': 'td cbi-section-actions mh-actions' }, E('div', [
					editable ? E('button', { 'class': 'btn cbi-button cbi-button-edit',
						'click': ui.createHandlerFn(this, 'editDialog', t.name, null) }, _('Edit')) : '',
					E('button', { 'class': 'btn cbi-button', 'title': _('Rename the interface'),
						'click': ui.createHandlerFn(this, 'renameDialog', t.name) }, _('Rename')),
					E('button', { 'class': 'btn cbi-button cbi-button-remove',
						'click': ui.createHandlerFn(this, 'deleteDialog', t.name, hidden, null) }, _('Delete'))
				]))
			]);
		});

		return E('div', Object.assign({ 'class': 'cbi-section' }, attrs || {}), [
			E('div', { 'class': 'cbi-section-descr' },
				_('A tunnel is a network interface: AmneziaWG, WireGuard, OpenVPN or another one. A tunnel section sends its traffic into it, and a proxy section can use it as one of its servers.')),
			E('div', { 'class': 'cbi-section-descr' },
				_('Every tunnel is also a server of the server list: choose it on the dashboard like any other server, or let the automatic choice by ping take it.')),
			...notes,
			rows.length ? E('table', { 'class': 'table mh-rtable' }, [
				E('tr', { 'class': 'tr table-titles' }, [
					E('th', { 'class': 'th' }, _('Tunnel name')), E('th', { 'class': 'th' }, _('Interface')), E('th', { 'class': 'th' }, _('Protocol')),
					E('th', { 'class': 'th' }, _('State')), E('th', { 'class': 'th' }, _('Sections')), E('th', { 'class': 'th' }, '')
				])
			].concat(rows)) : E('p', { 'class': 'mh-muted' }, _('No tunnels yet.')),
			E('button', { 'class': 'btn cbi-button-add', 'click': ui.createHandlerFn(this, 'importDialog', info) }, _('Import AmneziaWG / WireGuard…'))
		]);
	}
});
