'use strict';
'require view';
'require form';
'require uci';
'require rpc';
'require ui';
'require poll';
'require tools.widgets as widgets';
'require mayhem.vpnkey as vpnkey';
'require mayhem.common as mh';

const callGeo = rpc.declare({ object: 'luci.mayhem', method: 'geo', expect: { '': {} } });
const callDataUpdate = rpc.declare({ object: 'luci.mayhem', method: 'data_update', params: [ 'what', 'name' ], expect: { '': {} } });
const callGeoImport = rpc.declare({ object: 'luci.mayhem', method: 'geo_import', params: [ 'name', 'kind' ], expect: { '': {} } });
const callTunnelInfo = rpc.declare({ object: 'luci.mayhem', method: 'tunnel_info', expect: { '': {} } });
const callInstall = rpc.declare({ object: 'luci.mayhem', method: 'system_install', params: [ 'what' ], expect: { '': {} } });
const callImport = rpc.declare({ object: 'luci.mayhem', method: 'awg_import', params: [ 'name', 'conf', 'section' ], expect: { '': {} } });

const ROUTE_KERNEL = _('Kernel — the fastest. Traffic goes into the tunnel straight from the kernel, without xray: the best choice for games and calls. Domains, geosite, geoip and subnets work; keyword and regexp only work through the xray backup. Kernel sections always go before other sections.');
const ROUTE_XRAY = _('Through xray — more flexible. All rules work. To group the tunnel with VLESS and other servers and switch between them automatically, add it as a server of a proxy section instead. Speed is limited by xray.');

// Categories above this make xray use a lot of memory (same limit as the generator).
const HEAVY = 50000;

const LINK_RE = /^(vless|vmess|trojan|ss|socks5?|https?|hysteria2|hy2|wireguard|wg):\/\/\S+/i;
const DOMAIN_RE = /^(domain:|full:)?(\*\.|\.)?[a-z0-9_-]+(\.[a-z0-9_-]+)*\.?$/i;

function validateDomain(section_id, value) {
	if (!value)
		return true;

	if (/^(keyword|regexp):.+/.test(value) || DOMAIN_RE.test(value) ||
	    /^geosite:([A-Za-z0-9_]+:)?[a-z0-9][a-z0-9_!.-]*(@[a-z0-9!_-]+)?$/i.test(value))
		return true;

	return _('Expected a domain, or domain:, full:, keyword:, regexp:, geosite: rule');
}

function validateIP(section_id, value) {
	if (!value)
		return true;

	if (/^geoip:!?([A-Za-z0-9_]+:)?[a-z0-9][a-z0-9_.-]*$/i.test(value))
		return true;

	const v4 = /^(\d{1,3}\.){3}\d{1,3}(\/\d{1,2})?$/;
	const v6 = /^[0-9a-f:]+(\/\d{1,3})?$/i;

	return (v4.test(value) || (v6.test(value) && value.indexOf(':') >= 0))
		? true : _('Expected an IP address or a subnet in CIDR form');
}

function validateRegexp(section_id, value) {
	if (!value)
		return true;

	try {
		new RegExp(value);
		return true;
	}
	catch (e) {
		return _('Invalid regular expression');
	}
}

function formatCount(n) {
	return String(n).replace(/\B(?=(\d{3})+(?!\d))/g, ' ');
}

// Dropdown choices for geo categories: "geosite:youtube" for the first source
// that has a category, "geosite:source:category" for the others.
function geoChoices(o, kind, cats) {
	const seen = {};

	for (const c of cats) {
		const value = seen[c.name] ? '%s:%s:%s'.format(kind, c.source, c.name) : '%s:%s'.format(kind, c.name);
		const heavy = c.count > HEAVY ? ' ⚠ ' + _('heavy') : '';

		seen[c.name] = true;
		o.value(value, '%s — %s%s'.format(value, formatCount(c.count), heavy));
	}
}

// Asks for a source name and type, uploads the file, registers the source.
function uploadSource() {
	const name = E('input', { 'class': 'cbi-input-text', 'placeholder': 'my_geosite' });
	const kind = E('select', { 'class': 'cbi-input-select' }, [
		E('option', { 'value': 'geosite' }, 'geosite'),
		E('option', { 'value': 'geoip' }, 'geoip')
	]);

	ui.showModal(_('Upload a .dat file'), [
		E('p', _('The file is kept on the router as it is, so it must be small (up to 8 MB). Big files are better added by URL.')),
		E('div', { 'class': 'cbi-value' }, [ E('label', { 'class': 'cbi-value-title' }, _('Source name')), E('div', { 'class': 'cbi-value-field' }, name) ]),
		E('div', { 'class': 'cbi-value' }, [ E('label', { 'class': 'cbi-value-title' }, _('Type')), E('div', { 'class': 'cbi-value-field' }, kind) ]),
		E('div', { 'class': 'right' }, [
			E('button', { 'class': 'btn', 'click': ui.hideModal }, _('Cancel')), ' ',
			E('button', {
				'class': 'btn cbi-button-action',
				'click': ui.createHandlerFn(this, function() {
					if (!/^[A-Za-z0-9_]+$/.test(name.value)) {
						ui.addNotification(null, E('p', _('The name may only contain letters, digits and _')), 'error');
						return;
					}

					return ui.uploadFile('/tmp/mayhem-upload.dat').then(() => callGeoImport(name.value, kind.value)).then((r) => {
						ui.hideModal();

						if (r.error)
							ui.addNotification(null, E('p', r.error), 'error');
						else
							window.location.reload();
					}).catch((e) => ui.addNotification(null, E('p', e.message), 'error'));
				})
			}, _('Choose file…'))
		])
	]);
}

function since(ts) {
	if (!ts)
		return _('never');

	return new Date(ts * 1000).toLocaleString();
}

return view.extend({
	load() {
		return Promise.all([
			uci.load('mayhem'),
			L.resolveDefault(callGeo(), {}),
			L.resolveDefault(callTunnelInfo(), {})
		]);
	},

	// Installs AmneziaWG or dnsmasq-full in the background and shows its log.
	install(what) {
		return callInstall(what).then((r) => {
			if (r.error || r.busy) {
				ui.addNotification(null, E('p', r.error || _('An installation is already running')), 'error');
				return;
			}

			const log = E('pre', { 'style': 'max-height:20em;overflow:auto;white-space:pre-wrap' }, _('Starting…'));

			ui.showModal(what === 'awg' ? _('Installing AmneziaWG') : _('Installing dnsmasq-full'), [
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

	importTunnel(info) {
		const name = E('input', { 'class': 'cbi-input-text', 'value': 'awg0', 'maxlength': 15 });
		const text = E('textarea', {
			'class': 'cbi-input-textarea', 'rows': 10, 'style': 'width:100%;font-family:monospace',
			'placeholder': '[Interface]\nPrivateKey = …\n\nor vpn://…'
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
					? _('Interface %s and section %s are created. Add rules to the section, then save and apply.').format(r.interface, r.section)
					: _('Interface %s is created.').format(r.interface)), 'info');
				window.setTimeout(() => window.location.reload(), 1500);
			}).catch((e) => ui.addNotification(null, E('p', e.message), 'error'));
		};

		ui.showModal(_('Import a tunnel'), [
			E('p', _('Paste a WireGuard or AmneziaWG config (.conf) or an AmneziaVPN key (vpn://), or pick a .conf file. The tunnel is created without a default route: only traffic of Mayhem sections goes into it.')),
			info.awg ? '' : E('p', { 'style': 'color:#ef6c00' }, _('AmneziaWG is not installed: only plain WireGuard configs can be imported.')),
			E('div', { 'class': 'cbi-value' }, [ E('label', { 'class': 'cbi-value-title' }, _('Interface name')), E('div', { 'class': 'cbi-value-field' }, name) ]),
			E('div', { 'class': 'cbi-value' }, [ E('label', { 'class': 'cbi-value-title' }, _('Config or key')), E('div', { 'class': 'cbi-value-field' }, [ text, E('br'), file ]) ]),
			E('div', { 'class': 'cbi-value' }, [ E('label', { 'class': 'cbi-value-title' }, _('Create a section')), E('div', { 'class': 'cbi-value-field' }, section) ]),
			E('div', { 'class': 'right' }, [
				E('button', { 'class': 'btn', 'click': ui.hideModal }, _('Cancel')), ' ',
				E('button', { 'class': 'btn cbi-button-action', 'click': ui.createHandlerFn(this, submit) }, _('Import'))
			])
		]);
	},

	renderTunnels(info) {
		const kernel = uci.sections('mayhem', 'section').some((x) =>
			x.type === 'interface' && x.enabled !== '0' && (x.route_mode || 'kernel') === 'kernel');
		const notes = [];

		if (!info.awg)
			notes.push(E('p', [
				_('AmneziaWG is not installed.'), ' ',
				E('button', { 'class': 'btn cbi-button', 'click': ui.createHandlerFn(this, 'install', 'awg') }, _('Install AmneziaWG'))
			]));

		if (kernel && info.nftset === false)
			notes.push(E('p', { 'style': 'color:#ef6c00' }, [
				_('Tunnel sections in kernel mode need dnsmasq-full: until it is installed their domains go through xray.'), ' ',
				E('button', { 'class': 'btn cbi-button', 'click': ui.createHandlerFn(this, 'install', 'dnsmasq') }, _('Install dnsmasq-full'))
			]));

		return E('div', { 'class': 'cbi-section' }, [
			E('h3', _('Tunnels')),
			E('p', _('A tunnel section sends its traffic into a network interface: AmneziaWG, WireGuard, OpenVPN or any other.')),
			...notes,
			E('button', { 'class': 'btn cbi-button-add', 'click': ui.createHandlerFn(this, 'importTunnel', info) }, _('Import AmneziaWG / WireGuard…'))
		]);
	},

	render(data) {
		const geo = data[1] || {};
		const tun = data[2] || {};
		const cats = geo.categories || { geosite: [], geoip: [] };
		const noGeo = !cats.geosite.length && !cats.geoip.length
			? ' ' + _('Categories appear in the list after the first geo data download.') : '';

		const subs = uci.sections('mayhem', 'subscription').map((s) => s['.name']);

		const sourceInfo = {};

		(geo.sources || []).forEach((x) => sourceInfo[x.name] = x);

		const proxies = uci.sections('mayhem', 'section')
			.filter((x) => (x.type || 'proxy') === 'proxy')
			.map((x) => x['.name']);

		// Tabs: sections, DNS, geo files.
		const m = new form.Map('mayhem');

		m.tabbed = true;

		let s = m.section(form.GridSection, 'section', _('Sections'),
			_('A section is a set of rules and the way its traffic leaves the router. Sections are checked top to bottom; block sections always go first.'));
		s.addremove = true;
		s.anonymous = false;
		s.sortable = true;
		s.nodescriptions = true;
		s.addbtntitle = _('Add section');
		s.modaltitle = (section_id) => _('Section') + ' » ' + section_id;

		let o;

		o = s.option(form.Flag, 'enabled', _('Enabled'));
		o.default = '1';
		o.editable = true;
		o.rmempty = false;

		o = s.option(form.ListValue, 'type', _('Type'),
			_('Proxy: through a server. Tunnel: into a network interface (AmneziaWG, WireGuard…). Direct: bypass the proxy. Block: drop the traffic.'));
		o.value('proxy', _('Proxy'));
		o.value('interface', _('Tunnel'));
		o.value('exclusion', _('Direct'));
		o.value('block', _('Block'));
		o.default = 'proxy';
		o.textvalue = function(section_id) {
			const v = this.cfgvalue(section_id) || 'proxy';
			const i = this.keylist.indexOf(v);

			return i >= 0 ? this.vallist[i] : v;
		};

		o = s.option(widgets.NetworkSelect, 'interface', _('Interface'),
			_('The network interface of the tunnel. If the tunnel stops working (no handshake for 3 minutes), its traffic goes direct until it is back.'));
		o.nocreate = true;
		o.exclude = 'lan';
		o.depends('type', 'interface');
		o.modalonly = true;

		o = s.option(form.ListValue, 'route_mode', _('Routing'), ROUTE_KERNEL + '<br>' + ROUTE_XRAY);
		o.value('kernel', _('Kernel (fastest)'));
		o.value('xray', _('Through xray'));
		o.default = 'kernel';
		o.depends('type', 'interface');
		o.modalonly = true;

		o = s.option(form.ListValue, 'proxy_type', _('Servers from'));
		o.value('link', _('Links and subscriptions'));
		o.value('json', _('Xray outbound JSON'));
		o.default = 'link';
		o.depends('type', 'proxy');
		o.modalonly = true;

		o = s.option(form.DynamicList, 'link', _('Links'),
			_('One server per entry: vless://, vmess://, trojan://, ss://, socks://, http(s)://, hysteria2://, wireguard://'));
		o.depends({ type: 'proxy', proxy_type: 'link' });
		o.modalonly = true;
		o.validate = function(section_id, value) {
			return (!value || LINK_RE.test(value.trim())) ? true : _('Unsupported or malformed link');
		};

		o = s.option(form.MultiValue, 'subscription', _('Subscriptions'),
			subs.length ? _('Servers of these subscriptions are added to the section.')
				: _('No subscriptions yet: add them on the Subscriptions page.'));
		subs.forEach((n) => o.value(n));
		o.depends({ type: 'proxy', proxy_type: 'link' });
		o.modalonly = true;

		o = s.option(form.Value, 'filter', _('Take servers named'),
			_('Regular expression over server names, case-insensitive. Example: NL|DE'));
		o.depends({ type: 'proxy', proxy_type: 'link' });
		o.modalonly = true;
		o.validate = validateRegexp;

		o = s.option(form.Value, 'exclude', _('Skip servers named'));
		o.depends({ type: 'proxy', proxy_type: 'link' });
		o.modalonly = true;
		o.validate = validateRegexp;

		o = s.option(widgets.NetworkSelect, 'iface_node', _('Tunnels as servers'),
			_('Network interfaces (AmneziaWG, WireGuard…) that join the servers of this section: with automatic choice the fastest one wins.'));
		o.multiple = true;
		o.nocreate = true;
		o.exclude = 'lan';
		o.depends({ type: 'proxy', proxy_type: 'link' });
		o.modalonly = true;

		o = s.option(form.ListValue, 'select', _('Server choice'),
			_('With several servers. Automatic: the fastest by URL test, checked periodically; you can still pin a server on the dashboard. Manual: the server picked on the dashboard.'));
		o.value('auto', _('Automatic'));
		o.value('manual', _('Manual'));
		o.default = 'auto';
		o.depends({ type: 'proxy', proxy_type: 'link' });
		o.modalonly = true;

		o = s.option(form.TextValue, 'outbound_json', _('Outbound JSON'),
			_('A single Xray outbound object. Its tag is replaced automatically.'));
		o.rows = 12;
		o.monospace = true;
		o.depends({ type: 'proxy', proxy_type: 'json' });
		o.modalonly = true;
		o.validate = function(section_id, value) {
			try {
				const j = JSON.parse(value);

				return (j && (typeof j.protocol === 'string' || Array.isArray(j.outbounds) || Array.isArray(j)))
					? true : _('The object has no "protocol"');
			}
			catch (e) {
				return _('Invalid JSON: %s').format(e.message);
			}
		};

		o = s.option(form.DynamicList, 'domain', _('Domains'),
			_('example.com matches the domain and its subdomains. Prefixes: full: exact name, keyword: substring, regexp: regular expression, geosite: a category of geo data (pick from the list). Categories marked as heavy hold more than %s rules and make xray use a lot of memory.').format(formatCount(HEAVY)) + noGeo);
		o.modalonly = true;
		o.validate = validateDomain;
		geoChoices(o, 'geosite', cats.geosite);

		o = s.option(form.DynamicList, 'ip', _('IP addresses and subnets'),
			_('IPv4 or IPv6 addresses, CIDR allowed: 91.108.4.0/22. geoip: a category of geo data, geoip:!category everything except it. For direct and block sections the subnets are handled in the kernel and never reach xray.') + noGeo);
		o.modalonly = true;
		o.validate = validateIP;
		geoChoices(o, 'geoip', cats.geoip);

		o = s.option(form.DynamicList, 'list_url', _('Lists by URL'),
			_('Text lists with one domain, rule or subnet per line, "#" for comments. Downloaded and refreshed automatically (Settings → Geo data).'));
		o.modalonly = true;
		o.validate = function(section_id, value) {
			return (!value || /^https?:\/\/\S+$/.test(value)) ? true : _('Expected an http(s):// address');
		};

		o = s.option(form.DynamicList, 'list_file', _('Lists from files'),
			_('Files on the router in the same format, for example /etc/mayhem/my.lst.'));
		o.modalonly = true;
		o.validate = function(section_id, value) {
			return (!value || /^\/\S+$/.test(value)) ? true : _('Expected an absolute path');
		};

		o = s.option(form.Value, 'local_port', _('Local proxy port'),
			_('A SOCKS5 and HTTP proxy on the router that sends everything into this section, for apps and devices that can use a proxy. Reachable from the LAN; the firewall closes it from the internet.'));
		o.datatype = 'range(1024,65535)';
		o.placeholder = _('off');
		o.depends('type', 'proxy');
		o.depends('type', 'interface');
		o.modalonly = true;

		o = s.option(form.Value, 'local_user', _('Proxy user'), _('Leave empty for a proxy without a password.'));
		o.depends({ type: 'proxy', local_port: /.+/ });
		o.depends({ type: 'interface', local_port: /.+/ });
		o.modalonly = true;

		o = s.option(form.Value, 'local_pass', _('Proxy password'));
		o.password = true;
		o.depends({ type: 'proxy', local_port: /.+/ });
		o.depends({ type: 'interface', local_port: /.+/ });
		o.modalonly = true;

		o = s.option(form.DummyValue, '_servers', _('Servers'));
		o.modalonly = false;
		o.textvalue = function(section_id) {
			const get = (k) => L.toArray(this.map.data.get('mayhem', section_id, k));
			const type = this.map.data.get('mayhem', section_id, 'type') || 'proxy';

			if (type === 'interface')
				return '%s (%s)'.format(this.map.data.get('mayhem', section_id, 'interface') || '?',
					this.map.data.get('mayhem', section_id, 'route_mode') === 'xray' ? _('through xray') : _('kernel'));

			if (type !== 'proxy')
				return '—';

			if (this.map.data.get('mayhem', section_id, 'proxy_type') === 'json')
				return 'JSON';

			const parts = [];
			const links = get('link').length;

			if (links)
				parts.push(_('%d links').format(links));

			get('iface_node').forEach((n) => parts.push(n));

			get('subscription').forEach((n) => parts.push(n));

			return parts.join(', ') || _('none');
		};

		o = s.option(form.DummyValue, '_rules', _('Rules'));
		o.modalonly = false;
		o.textvalue = function(section_id) {
			const d = L.toArray(this.map.data.get('mayhem', section_id, 'domain')).length;
			const i = L.toArray(this.map.data.get('mayhem', section_id, 'ip')).length;
			const l = L.toArray(this.map.data.get('mayhem', section_id, 'list_url')).length +
				L.toArray(this.map.data.get('mayhem', section_id, 'list_file')).length;
			const t = _('%d domains, %d addresses').format(d, i);

			return l ? t + ', ' + _('%d lists').format(l) : t;
		};

		s = m.section(form.NamedSection, 'dns', 'dns', _('DNS'),
			_('Direct traffic is resolved by the domestic DNS, proxied traffic by the remote DNS. The first server in a list is the main one, the next ones are fallbacks. Xray has no DNS-over-TLS: use https:// (DoH), tcp:// or a plain address.'));
		s.addremove = false;

		o = s.option(form.DynamicList, 'domestic', _('Domestic DNS'),
			_('Empty: DNS servers received from the provider.'));
		o.placeholder = '77.88.8.8';

		o = s.option(form.DynamicList, 'remote', _('Remote DNS'));
		o.placeholder = 'https://1.1.1.1/dns-query';

		o = s.option(form.Flag, 'via_proxy', _('Remote DNS through proxy'),
			_('Off: remote DNS queries go direct (encrypted with DoH).'));

		o = s.option(form.ListValue, 'proxy_section', _('Section for DNS'));
		o.value('', _('Default section'));
		proxies.forEach((n) => o.value(n));
		o.depends('via_proxy', '1');

		o = s.option(form.Flag, 'hijack', _('Intercept DNS on port 53'),
			_('Devices that use their own DNS server (8.8.8.8 and so on) are answered by Mayhem as well.'));
		o.default = '1';
		o.rmempty = false;

		o = s.option(form.Flag, 'fakedns', _('FakeDNS'),
			_('Proxied domains get addresses from 198.18.0.0/15. Helps when an app hides the domain, but cached fake addresses break if Mayhem stops.'));

		s = m.section(form.NamedSection, 'geo', 'geo', 'GeoFiles',
			_('geosite and geoip files are read on the router while they download; only the categories used in sections are kept, so a 70 MB file takes a few hundred kilobytes of flash. New categories are downloaded within a minute after saving, the rest is refreshed nightly.'));
		s.addremove = false;

		o = s.option(form.ListValue, 'update_hour', _('Nightly update at'));
		for (let h = 0; h < 24; h++)
			o.value(String(h), '%02d:00'.format(h));
		o.default = '4';

		o = s.option(form.ListValue, 'update_via', _('Download'),
			_('Applies to geo data and lists.'));
		o.value('auto', _('Direct, then through a section'));
		o.value('direct', _('Direct only'));
		o.value('section', _('Through a section only'));
		o.default = 'auto';

		o = s.option(form.ListValue, 'update_section', _('Section for downloads'));
		o.value('', _('First proxy section'));
		proxies.forEach((n) => o.value(n));
		o.depends('update_via', 'auto');
		o.depends('update_via', 'section');

		o = s.option(form.ListValue, 'lists_interval', _('Refresh lists every'));
		o.value('6', _('6 hours'));
		o.value('12', _('12 hours'));
		o.value('24', _('24 hours'));
		o.value('72', _('3 days'));
		o.default = '24';

		o = s.option(form.Button, '_upload_geo', _('Own file'));
		o.inputtitle = _('Upload .dat…');
		o.inputstyle = 'action';
		o.onclick = uploadSource;

		o = s.option(form.Button, '_update_geo', _('Update now'));
		o.inputtitle = _('Download geo data');
		o.inputstyle = 'action';
		o.onclick = function() {
			return callDataUpdate('geo', '').then((r) => {
				ui.addNotification(null, E('p', r.busy ? _('An update is already running')
					: _('The update runs in the background. Reopen this tab in a few minutes to see the result.')), 'info');
			});
		};

		o = s.option(form.SectionValue, '_sources', form.GridSection, 'geo_source', _('Geo sources'),
			_('Sections refer to categories as geosite:category or geosite:source:category. When several sources have a category, the first one in this list wins.'));
		s = o.subsection;
		s.addremove = true;
		s.anonymous = false;
		s.sortable = true;
		s.nodescriptions = true;
		s.addbtntitle = _('Add source');

		o = s.option(form.Flag, 'enabled', _('Enabled'));
		o.default = '1';
		o.editable = true;
		o.rmempty = false;

		o = s.option(form.ListValue, 'kind', _('Type'));
		o.value('geosite', 'geosite');
		o.value('geoip', 'geoip');
		o.default = 'geosite';

		o = s.option(form.Value, 'url', _('URL or file'),
			_('https:// address of a .dat file, or a path to a file on the router.'));
		o.rmempty = false;
		o.validate = function(section_id, value) {
			return (/^(https?:\/\/\S+|file:\/\/\/\S+|\/\S+)$/).test(value || '') ? true : _('Expected an http(s):// address or a file path');
		};

		o = s.option(form.DummyValue, '_state', _('State'));
		o.modalonly = false;
		o.textvalue = function(section_id) {
			const x = sourceInfo[section_id];

			if (!x)
				return _('not downloaded yet');

			if (x.error)
				return E('span', { 'style': 'color:#c62828' }, x.error);

			if (x.categories == null)
				return _('not downloaded yet');

			return _('%d categories, %d in use, updated %s').format(x.categories, x.copied.length, since(x.updated));
		};

		return m.render().then((node) => {
			// Tunnels and the category hint belong to the sections tab.
			const pane = node.querySelector('.cbi-section[data-tab="section"]') || node;

			node.insertBefore(mh.style(), node.firstChild);

			pane.appendChild(this.renderTunnels(tun));

			if (!noGeo)
				return node;

			// Without a download there is no category list to pick from.
			const btn = E('button', {
				'class': 'btn cbi-button-action',
				'click': ui.createHandlerFn(this, () => callDataUpdate('geo', '').then((r) => {
					ui.addNotification(null, E('p', r.busy ? _('An update is already running')
						: _('Downloading geo data in the background. Reopen this page in a few minutes.')), 'info');
				}))
			}, _('Download the category list'));

			pane.insertBefore(E('div', { 'class': 'cbi-section' }, [
				E('p', _('geosite and geoip categories have not been downloaded yet.')), btn
			]), pane.firstChild);

			return node;
		});
	}
});
