'use strict';
'require baseclass';
'require rpc';
'require ui';
'require poll';
'require uci';
'require mayhem.vpnkey as vpnkey';

// Tunnels: network interfaces (AmneziaWG, WireGuard and others) that tunnel
// sections and proxy sections use. Lists them, imports configs and keys,
// installs AmneziaWG and dnsmasq-full.

const callTunnelInfo = rpc.declare({ object: 'luci.mayhem', method: 'tunnel_info', expect: { '': {} } });
const callInstall = rpc.declare({ object: 'luci.mayhem', method: 'system_install', params: [ 'what', 'version' ], expect: { '': {} } });
const callImport = rpc.declare({ object: 'luci.mayhem', method: 'awg_import', params: [ 'name', 'conf', 'section' ], expect: { '': {} } });

const TUNNEL_PROTOS = [ 'amneziawg', 'wireguard', 'openvpn', 'openconnect', 'vpnc', 'l2tp', 'pptp' ];

const NAMES = {
	amneziawg: 'AmneziaWG', wireguard: 'WireGuard', openvpn: 'OpenVPN', openconnect: 'OpenConnect',
	vpnc: 'VPNC', l2tp: 'L2TP', pptp: 'PPTP'
};

const TITLES = {
	awg: _('Installing AmneziaWG'),
	dnsmasq: _('Installing dnsmasq-full'),
	xray: _('Updating Xray'),
	mayhem: _('Updating Mayhem')
};

return baseclass.extend({
	info() {
		return L.resolveDefault(callTunnelInfo(), {});
	},

	// Runs an installation in the background and shows its log until it ends.
	install(what, version) {
		return callInstall(what, version || '').then((r) => {
			if (r.error || r.busy) {
				ui.addNotification(null, E('p', r.error || _('An installation is already running')), 'error');
				return;
			}

			const log = E('pre', { 'style': 'max-height:20em;overflow:auto;white-space:pre-wrap' }, _('Starting…'));

			ui.showModal(TITLES[what] || _('Installation'), [
				E('p', _('This takes a minute. Do not close the page.')), log
			]);

			const check = () => callTunnelInfo().then((t) => {
				const inst = t.install || {};

				log.textContent = inst.log || '';

				if (inst.running)
					return;

				poll.remove(check);
				ui.showModal(null, [
					log,
					E('p', inst.rc === '0' ? _('Done.') : _('Failed, see the log above. Nothing else was changed.')),
					E('div', { 'class': 'right' }, E('button', { 'class': 'btn', 'click': () => window.location.reload() }, _('Close')))
				]);
			});

			poll.add(check, 3);
		});
	},

	importDialog(info) {
		const name = E('input', { 'class': 'cbi-input-text', 'value': 'awg0', 'maxlength': 15 });
		const text = E('textarea', {
			'class': 'cbi-input-textarea', 'rows': 10, 'style': 'width:100%;font-family:monospace',
			'placeholder': '[Interface]\nPrivateKey = …\n\nvpn://…'
		});
		const file = E('input', { 'type': 'file', 'accept': '.conf,.txt' });
		const section = E('input', { 'type': 'checkbox', 'checked': '' });

		file.addEventListener('change', () => {
			const f = file.files[0];

			if (f)
				f.text().then((t) => text.value = t);
		});

		const submit = () => {
			const raw = text.value.trim();

			if (!/^[a-z][a-z0-9_]{0,14}$/.test(name.value)) {
				ui.addNotification(null, E('p', _('The interface name must start with a letter: up to 15 lower-case letters, digits and _')), 'error');
				return Promise.resolve();
			}

			const conf = vpnkey.isKey(raw) ? vpnkey.decode(raw) : Promise.resolve(raw);

			return conf.then((c) => callImport(name.value, c, section.checked)).then((r) => {
				if (r.error) {
					ui.addNotification(null, E('p', r.error), 'error');
					return;
				}

				ui.hideModal();
				ui.addNotification(null, E('p', r.section
					? _('Interface %s and section %s are created. Add rules to the section on the Routing page.').format(r.interface, r.section)
					: _('Interface %s is created.').format(r.interface)), 'info');
				window.setTimeout(() => window.location.reload(), 1500);
			}).catch((e) => ui.addNotification(null, E('p', e.message), 'error'));
		};

		ui.showModal(_('Import a tunnel'), [
			E('p', _('Paste a WireGuard or AmneziaWG config (.conf) or an AmneziaVPN key (vpn://), or pick a .conf file. The tunnel is created without a default route: only traffic of Mayhem sections goes into it.')),
			info.awg ? '' : E('p', { 'class': 'mh-warn' }, _('AmneziaWG is not installed: only plain WireGuard configs can be imported.')),
			E('div', { 'class': 'cbi-value' }, [ E('label', { 'class': 'cbi-value-title' }, _('Interface name')), E('div', { 'class': 'cbi-value-field' }, name) ]),
			E('div', { 'class': 'cbi-value' }, [ E('label', { 'class': 'cbi-value-title' }, _('Config or key')), E('div', { 'class': 'cbi-value-field' }, [ text, E('br'), file ]) ]),
			E('div', { 'class': 'cbi-value' }, [ E('label', { 'class': 'cbi-value-title' }, _('Create a section')), E('div', { 'class': 'cbi-value-field' }, section) ]),
			E('div', { 'class': 'right' }, [
				E('button', { 'class': 'btn', 'click': ui.hideModal }, _('Cancel')), ' ',
				E('button', { 'class': 'btn cbi-button-action', 'click': ui.createHandlerFn(this, submit) }, _('Import'))
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
			notes.push(E('p', [
				_('AmneziaWG is not installed.'), ' ',
				E('button', { 'class': 'btn cbi-button', 'click': ui.createHandlerFn(this, 'install', 'awg') }, _('Install AmneziaWG'))
			]));

		if (kernel && info.nftset === false)
			notes.push(E('p', { 'class': 'mh-warn' }, [
				_('Tunnel sections in kernel mode need dnsmasq-full: until it is installed, their domains go through Xray.'), ' ',
				E('button', { 'class': 'btn cbi-button', 'click': ui.createHandlerFn(this, 'install', 'dnsmasq') }, _('Install dnsmasq-full'))
			]));

		const rows = tunnels.map((t) => E('tr', { 'class': 'tr' }, [
			E('td', { 'class': 'td' }, E('b', t.name)),
			E('td', { 'class': 'td' }, NAMES[t.proto] || t.proto),
			E('td', { 'class': 'td' }, t.up ? E('span', { 'class': 'mh-ok' }, '✔ ' + _('Works')) : E('span', { 'class': 'mh-fail' }, '✘ ' + _('Does not work'))),
			E('td', { 'class': 'td' }, usedBy(t.name).join(', ') || E('span', { 'class': 'mh-muted' }, _('Not used')))
		]));

		return E('div', Object.assign({ 'class': 'cbi-section' }, attrs || {}), [
			E('div', { 'class': 'cbi-section-descr' },
				_('A tunnel is a network interface: AmneziaWG, WireGuard, OpenVPN or another one. A tunnel section sends its traffic into it, and a proxy section can use it as one of its servers.')),
			...notes,
			rows.length ? E('table', { 'class': 'table' }, [
				E('tr', { 'class': 'tr table-titles' }, [
					E('th', { 'class': 'th' }, _('Interface')), E('th', { 'class': 'th' }, _('Protocol')),
					E('th', { 'class': 'th' }, _('State')), E('th', { 'class': 'th' }, _('Sections'))
				])
			].concat(rows)) : E('p', { 'class': 'mh-muted' }, _('No tunnels yet.')),
			E('button', { 'class': 'btn cbi-button-add', 'click': ui.createHandlerFn(this, 'importDialog', info) }, _('Import AmneziaWG / WireGuard…'))
		]);
	}
});
