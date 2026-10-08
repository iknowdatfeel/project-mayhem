'use strict';
'require view';
'require form';
'require uci';
'require rpc';
'require ui';
'require tools.widgets as widgets';
'require mayhem.common as mh';

// Routing: the sections with their rules and the switches that apply to all
// traffic, DNS, geo files. A section opens in a dialog: type, servers, then
// rules (ready categories, own domains and addresses as text or as a list,
// rule lists); rarely needed options behind "Advanced settings".

const callGeo = rpc.declare({ object: 'luci.mayhem', method: 'geo', expect: { '': {} } });
const callDataUpdate = rpc.declare({ object: 'luci.mayhem', method: 'data_update', params: [ 'what', 'name' ], expect: { '': {} } });
const callGeoImport = rpc.declare({ object: 'luci.mayhem', method: 'geo_import', params: [ 'name', 'kind' ], expect: { '': {} } });
const callDashboard = rpc.declare({ object: 'luci.mayhem', method: 'dashboard', expect: { '': {} } });
const callRename = rpc.declare({ object: 'luci.mayhem', method: 'rename_section', params: [ 'name', 'new_name' ], expect: { '': {} } });

const ROUTE_KERNEL = _('Kernel is the fastest: traffic goes into the tunnel straight from the kernel, without Xray. The best choice for games and calls. Domains, geosite, geoip and subnets work; keyword and regexp rules only work through the Xray backup. Kernel sections always go before the other sections.');
const ROUTE_XRAY = _('Through Xray is more flexible: every rule works. Speed is limited by Xray.');

// Categories above this make xray use a lot of memory (same limit as the generator).
const HEAVY = 50000;

// Public resolvers for the DNS lists: [ label, DoH address ].
const RESOLVERS = [
	[ 'Cloudflare', 'https://1.1.1.1/dns-query' ],
	[ 'Google', 'https://8.8.8.8/dns-query' ],
	[ 'Quad9', 'https://9.9.9.9/dns-query' ],
	[ 'AdGuard', 'https://dns.adguard-dns.com/dns-query' ],
	[ 'Yandex', 'https://common.dot.dns.yandex.net/dns-query' ],
	[ 'Comss DNS', 'https://dns.comss.one/dns-query' ],
	[ 'Xbox DNS', 'https://xbox-dns.ru/dns-query' ]
];

// Known geo data sources: [ kind, provider, URL ].
const GEO_PRESETS = [
	[ 'geosite', 'runetfreedom', 'https://github.com/runetfreedom/russia-v2ray-rules-dat/releases/latest/download/geosite.dat' ],
	[ 'geoip', 'runetfreedom', 'https://github.com/runetfreedom/russia-v2ray-rules-dat/releases/latest/download/geoip.dat' ],
	[ 'geosite', 'Loyalsoldier', 'https://github.com/Loyalsoldier/v2ray-rules-dat/releases/latest/download/geosite.dat' ],
	[ 'geoip', 'Loyalsoldier', 'https://github.com/Loyalsoldier/v2ray-rules-dat/releases/latest/download/geoip.dat' ],
	[ 'geosite', 'MetaCubeX', 'https://github.com/MetaCubeX/meta-rules-dat/releases/latest/download/geosite.dat' ],
	[ 'geoip', 'MetaCubeX', 'https://github.com/MetaCubeX/meta-rules-dat/releases/latest/download/geoip.dat' ],
	[ 'geosite', 'v2fly', 'https://github.com/v2fly/domain-list-community/releases/latest/download/dlc.dat' ],
	[ 'geoip', 'v2fly', 'https://github.com/v2fly/geoip/releases/latest/download/geoip.dat' ]
];

// A proxy section without servers of its own uses the server list. Older
// configs have no "servers" option: links, subscriptions, a JSON outbound or
// tunnels as servers mean servers of its own (as on the router).
function ownServers(data, sid) {
	const v = data.get('mayhem', sid, 'servers');

	if (v === 'own' || v === 'pool')
		return v === 'own';

	return L.toArray(data.get('mayhem', sid, 'link')).length > 0 || L.toArray(data.get('mayhem', sid, 'subscription')).length > 0 ||
		data.get('mayhem', sid, 'proxy_type') === 'json' || L.toArray(data.get('mayhem', sid, 'iface_node')).length > 0;
}

const DOMAIN_RE = /^(domain:|full:)?(\*\.|\.)?[a-z0-9_-]+(\.[a-z0-9_-]+)*\.?$/i;
const GEOSITE_RE = /^geosite:([A-Za-z0-9_]+:)?[a-z0-9][a-z0-9_!.-]*(@[a-z0-9!_-]+)?$/i;
const GEOIP_RE = /^geoip:!?([A-Za-z0-9_]+:)?[a-z0-9][a-z0-9_.-]*$/i;
const IP4_RE = /^(\d{1,3}\.){3}\d{1,3}(\/\d{1,2})?$/;
const IP6_RE = /^[0-9a-f:]+(\/\d{1,3})?$/i;
const LINK_RE = /^(vless|vmess|trojan|ss|socks5?|https?|hysteria2|hy2|wireguard|wg):\/\/\S+/i;

function isIp(v) {
	return GEOIP_RE.test(v) || IP4_RE.test(v) || (IP6_RE.test(v) && v.indexOf(':') >= 0);
}

function isGeo(v) {
	return (/^(geosite|geoip):/i).test(v);
}

function domainError(v) {
	if (/^(keyword|regexp):.+/.test(v) || DOMAIN_RE.test(v) || GEOSITE_RE.test(v))
		return null;

	return _('"%s" is not a domain, an IP address or a rule').format(v);
}

function validateDomain(section_id, value) {
	return (!value || !domainError(value)) ? true : domainError(value);
}

function validateIP(section_id, value) {
	return (!value || isIp(value)) ? true : _('Expected an IP address or a subnet in CIDR form');
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

// Domains and addresses typed as text: one per line, commas and spaces
// also separate them, "#" starts a comment.
function tokens(text) {
	const out = [];

	String(text || '').split('\n').forEach((line) => {
		line.replace(/#.*$/, '').split(/[\s,]+/).forEach((t) => {
			if (t)
				out.push(t);
		});
	});

	return out;
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
		const heavy = c.count > HEAVY ? ' ⚠ ' + _('Heavy') : '';

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

function renameSection(name) {
	const input = E('input', { 'class': 'cbi-input-text', 'value': name });

	ui.showModal(_('Rename section %s').format(name), [
		E('p', _('Latin letters, digits and _. The settings that name the section change too. Xray restarts once, so connections break for a moment.')),
		input,
		E('div', { 'class': 'right' }, [
			E('button', { 'class': 'btn', 'click': ui.hideModal }, _('Cancel')), ' ',
			E('button', {
				'class': 'btn cbi-button-action',
				'click': ui.createHandlerFn(this, () => {
					const to = input.value.trim();

					if (to === name)
						return ui.hideModal();

					if (!/^[A-Za-z0-9_]+$/.test(to)) {
						ui.addNotification(null, E('p', _('The section name may only contain letters, digits and _')), 'error');
						return;
					}

					return callRename(name, to).then((r) => {
						if (r.error) {
							ui.addNotification(null, E('p', r.error), 'error');
							return;
						}

						window.location.reload();
					});
				})
			}, _('Rename'))
		])
	]);
}

// Reads a list option of the section being edited (staged values included).
function list(o, sid, opt) {
	return L.toArray(o.map.data.get(o.map.config, sid, opt));
}

function setList(o, sid, opt, values) {
	if (values.length)
		o.map.data.set(o.map.config, sid, opt, values);
	else
		o.map.data.unset(o.map.config, sid, opt);
}

// Options behind "Advanced settings" keep their values while it is off.
function keepHidden(o) {
	o.remove = function(sid) {
		if (this.isActive(sid))
			return form.Value.prototype.remove.call(this, sid);
	};
}

// Servers come from keys and subscriptions unless the section has an outbound
// JSON (an advanced option, so its field may be hidden). Visibility follows
// checkDepends: LuCI shows or hides a field when the two disagree.
function onJson(o, want) {
	const base = o.checkDepends;

	o.checkDepends = function(sid) {
		if (!base.call(this, sid))
			return false;

		const pt = this.section.children.filter((c) => c.option === 'proxy_type')[0];
		const v = (pt && pt.isActive(sid)) ? pt.formvalue(sid) : this.map.data.get('mayhem', sid, 'proxy_type');

		return (v === 'json') === want;
	};
}

function notJson(o) {
	onJson(o, false);
}

// The domain and ip lists hold everything; the fields of the dialog are views
// of parts of them: geo categories, own entries as text or as lists. Each one
// writes back only its part. A field that is hidden keeps its part.
function viewOf(o, part, write) {
	o.write = function(sid, value) {
		write.call(this, sid, value);
	};
	o.remove = function(sid) {
		if (this.isActive(sid))
			write.call(this, sid, part === 'text' ? '' : []);
	};
}

return view.extend({
	load() {
		return Promise.all([
			uci.load([ 'mayhem', 'network' ]),
			L.resolveDefault(callGeo(), {}),
			L.resolveDefault(callDashboard(), {})
		]);
	},

	render(data) {
		const geo = data[1] || {};
		const dash = data[2] || {};
		const cats = geo.categories || { geosite: [], geoip: [] };
		const noGeo = !cats.geosite.length && !cats.geoip.length;
		const subs = uci.sections('mayhem', 'subscription').map((s) => s['.name']);
		const sourceInfo = {};
		const servers = {};

		(geo.sources || []).forEach((x) => sourceInfo[x.name] = x);
		(dash.sections || []).forEach((x) => servers[x.name] = (x.nodes || []).map((n) => n.name));

		const m = new form.Map('mayhem');
		let s, o;

		m.tabbed = true;

		// --- sections and the switches for all traffic ---

		s = m.section(form.NamedSection, 'settings', 'settings', _('Sections'));
		s.addremove = false;

		// The active server is chosen on the dashboard; here it is shown.
		const now = mh.mainServerText(dash);

		o = s.option(form.Flag, 'mode', _('The rest of the traffic through the tunnel'),
			now ? _('Traffic that matches no rule goes through the active server, now %s. When this is off, it goes direct.').format(now)
				: _('Traffic that matches no rule goes through the active server. When this is off, it goes direct.'));
		o.enabled = 'global';
		o.disabled = 'lists';
		o.default = 'lists';
		o.rmempty = false;

		o = s.option(form.Flag, 'exclude_local', _('Keep local addresses out of routing'),
			_('Addresses of local networks (10.0.0.0/8, 192.168.0.0/16 and others) always go direct.'));
		o.default = '1';
		o.rmempty = false;

		o = s.option(form.Flag, 'block_quic', _('Turn QUIC off'),
			_('Browsers and apps fall back from QUIC (UDP 443) to TCP, which works better through a proxy.'));
		o.rmempty = false;

		o = s.option(form.Flag, 'torrent_direct', _('Torrents direct'),
			_('Xray recognizes BitTorrent by its first packets and sends it direct, past the proxy.'));
		o.rmempty = false;

		o = s.option(form.SectionValue, '_sections', form.GridSection, 'section', _('Sections'),
			_('A section is a set of rules and the way its traffic leaves the router. Sections are checked from top to bottom; blocking always goes first.'));

		const ss = o.subsection;

		ss.addremove = true;
		ss.anonymous = false;
		ss.sortable = true;
		ss.nodescriptions = true;
		ss.addbtntitle = _('Add section');
		ss.modaltitle = (section_id) => _('Section') + ' » ' + section_id;

		// A rename button next to "Edit".
		ss.renderRowActions = function(section_id) {
			const td = form.GridSection.prototype.renderRowActions.apply(this, arguments);
			const box = td.querySelector('div') || td;

			box.insertBefore(E('button', {
				'class': 'btn cbi-button cbi-button-neutral mh-rename',
				'title': _('Rename'),
				'click': ui.createHandlerFn(this, (ev) => { ev.preventDefault(); renameSection(section_id); })
			}, '✎'), box.firstChild);

			return td;
		};

		o = ss.option(form.Flag, 'enabled', _('Enabled'));
		o.default = '1';
		o.editable = true;
		o.rmempty = false;

		o = ss.option(form.ListValue, 'type', _('Type'),
			_('Proxy: through a server. Tunnel: into a network interface (AmneziaWG, WireGuard…). Direct: past the proxy. Block: the traffic is dropped.'));
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

		// --- servers of a proxy section ---

		// A section is a routing rule: by default its traffic goes through the
		// active server of the server list; a separate server is for domains
		// that need one of their own.
		o = ss.option(form.ListValue, 'servers', _('Server'),
			now ? _('The active server of the server list is the one chosen on the dashboard, now %s. A separate server is for domains that need a server of their own.').format(now)
				: _('The active server of the server list is the one chosen on the dashboard. A separate server is for domains that need a server of their own.'));
		o.value('pool', _('Active server of the server list'));
		o.value('own', _('Separate server'));
		o.depends('type', 'proxy');
		o.modalonly = true;
		o.rmempty = false;
		keepHidden(o);
		o.cfgvalue = function(sid) {
			return ownServers(this.map.data, sid) ? 'own' : 'pool';
		};

		o = ss.option(form.TextValue, '_links', _('Server keys'),
			_('One key per line: vless://, vmess://, trojan://, ss://, socks://, http(s)://, hysteria2://, wireguard://'));
		o.rows = 4;
		o.monospace = true;
		o.wrap = 'off';
		o.modalonly = true;
		o.depends('type', 'proxy');
		notJson(o);
		o.cfgvalue = function(sid) {
			return list(this, sid, 'link').join('\n');
		};
		o.validate = function(sid, value) {
			const bad = String(value || '').split('\n').map((l) => l.trim())
				.filter((l) => l && l.charAt(0) !== '#' && !LINK_RE.test(l))[0];

			return bad ? _('Not a server key: %s').format(bad.slice(0, 60)) : true;
		};
		viewOf(o, 'text', function(sid, value) {
			setList(this, sid, 'link', String(value || '').split('\n').map((l) => l.trim()).filter((l) => l && l.charAt(0) !== '#'));
		});

		o = ss.option(form.MultiValue, 'subscription', _('Subscriptions'),
			subs.length ? _('Servers of these subscriptions are added to the section.')
				: _('No subscriptions yet: add them on the Server list page.'));
		subs.forEach((n) => o.value(n));
		o.depends('type', 'proxy');
		notJson(o);
		keepHidden(o);
		o.modalonly = true;

		o = ss.option(form.ListValue, 'override', _('Server by default'),
			_('Without it the fastest server by URL test is used. Either way, another server can be picked on the dashboard.'));
		o.value('', _('The fastest (automatic)'));
		o.depends('type', 'proxy');
		o.modalonly = true;
		o.cfgvalue = function(sid) {
			const cur = this.map.data.get('mayhem', sid, 'override') || this.map.data.get('mayhem', sid, 'selected');
			const names = (servers[sid] || []).slice();

			if (cur && names.indexOf(cur) < 0)
				names.push(cur);

			// The choices are the servers of this section only.
			this.keylist = [ '' ];
			this.vallist = [ _('The fastest (automatic)') ];
			names.forEach((n) => this.value(n));

			return cur || '';
		};
		o.write = function(sid, value) {
			this.map.data.set('mayhem', sid, 'override', value);
			this.map.data.set('mayhem', sid, 'select', 'auto');
			this.map.data.unset('mayhem', sid, 'selected');
		};
		o.remove = function(sid) {
			if (!this.isActive(sid))
				return;

			this.map.data.unset('mayhem', sid, 'override');
			this.map.data.unset('mayhem', sid, 'selected');

			if (this.map.data.get('mayhem', sid, 'select'))
				this.map.data.set('mayhem', sid, 'select', 'auto');
		};

		// --- a tunnel section ---

		o = ss.option(widgets.NetworkSelect, 'interface', _('Interface'),
			_('The network interface of the tunnel. When the tunnel stops working (no handshake for 3 minutes), its traffic goes direct until it is back.'));
		o.nocreate = true;
		o.exclude = 'lan';
		o.depends('type', 'interface');
		o.modalonly = true;

		o = ss.option(form.ListValue, 'route_mode', _('Routing'), ROUTE_KERNEL + '<br>' + ROUTE_XRAY);
		o.value('kernel', _('Kernel (fastest)'));
		o.value('xray', _('Through Xray'));
		o.default = 'kernel';
		o.depends('type', 'interface');
		o.modalonly = true;

		// --- rules ---

		o = ss.option(form.DynamicList, '_cats', _('Ready categories'),
			_('Categories of geo data: geosite for domains, geoip for addresses. Categories marked as heavy hold more than %s rules and make Xray use a lot of memory.').format(formatCount(HEAVY)) +
			(noGeo ? ' ' + _('Categories appear in the list after the first geo data download.') : ''));
		o.modalonly = true;
		geoChoices(o, 'geosite', cats.geosite);
		geoChoices(o, 'geoip', cats.geoip);
		o.cfgvalue = function(sid) {
			return list(this, sid, 'domain').filter(isGeo).concat(list(this, sid, 'ip').filter(isGeo));
		};
		o.validate = function(sid, value) {
			return (!value || GEOSITE_RE.test(value) || GEOIP_RE.test(value)) ? true : _('Expected geosite:category or geoip:category');
		};
		viewOf(o, 'list', function(sid, value) {
			const v = L.toArray(value);

			setList(this, sid, 'domain', list(this, sid, 'domain').filter((x) => !isGeo(x)).concat(v.filter((x) => (/^geosite:/i).test(x))));
			setList(this, sid, 'ip', list(this, sid, 'ip').filter((x) => !isGeo(x)).concat(v.filter((x) => (/^geoip:/i).test(x))));
		});

		o = ss.option(form.ListValue, 'rules_input', _('Own domains and addresses'));
		o.value('text', _('As text'));
		o.value('list', _('As a list'));
		o.default = 'text';
		o.modalonly = true;

		o = ss.option(form.TextValue, '_text', _('Domains and IP addresses'),
			_('One per line, or separated by commas or spaces; "#" starts a comment. example.com matches the domain and its subdomains; full: is the exact name, keyword: a substring, regexp: a regular expression. Addresses and subnets: 91.108.4.0/22, 2001:db8::/32.'));
		o.rows = 8;
		o.monospace = true;
		o.placeholder = 'example.com\nfull:www.example.org\n91.108.4.0/22\n# Comment';
		o.depends('rules_input', 'text');
		o.modalonly = true;
		o.cfgvalue = function(sid) {
			return list(this, sid, 'domain').filter((x) => !isGeo(x)).concat(list(this, sid, 'ip').filter((x) => !isGeo(x))).join('\n');
		};
		o.validate = function(sid, value) {
			for (const t of tokens(value)) {
				if (isIp(t))
					continue;

				const e = domainError(t);

				if (e)
					return e;
			}

			return true;
		};
		viewOf(o, 'text', function(sid, value) {
			const t = tokens(value);

			setList(this, sid, 'domain', list(this, sid, 'domain').filter(isGeo).concat(t.filter((x) => !isIp(x))));
			setList(this, sid, 'ip', list(this, sid, 'ip').filter(isGeo).concat(t.filter(isIp)));
		});

		o = ss.option(form.DynamicList, '_domains', _('Domains'),
			_('example.com matches the domain and its subdomains; full: is the exact name, keyword: a substring, regexp: a regular expression.'));
		o.depends('rules_input', 'list');
		o.modalonly = true;
		o.validate = validateDomain;
		o.cfgvalue = function(sid) {
			return list(this, sid, 'domain').filter((x) => !isGeo(x));
		};
		viewOf(o, 'list', function(sid, value) {
			setList(this, sid, 'domain', list(this, sid, 'domain').filter(isGeo).concat(L.toArray(value)));
		});

		o = ss.option(form.DynamicList, '_ips', _('IP addresses and subnets'),
			_('IPv4 or IPv6 addresses, CIDR allowed: 91.108.4.0/22.'));
		o.depends('rules_input', 'list');
		o.modalonly = true;
		o.validate = validateIP;
		o.cfgvalue = function(sid) {
			return list(this, sid, 'ip').filter((x) => !isGeo(x));
		};
		viewOf(o, 'list', function(sid, value) {
			setList(this, sid, 'ip', list(this, sid, 'ip').filter(isGeo).concat(L.toArray(value)));
		});

		o = ss.option(form.DynamicList, 'list_url', _('Lists by URL'),
			_('Text lists with one domain, rule or subnet per line, "#" for comments. They are downloaded and updated automatically.'));
		o.modalonly = true;
		o.validate = function(section_id, value) {
			return (!value || /^https?:\/\/\S+$/.test(value)) ? true : _('Expected an http(s):// address');
		};

		o = ss.option(form.DynamicList, 'list_file', _('Lists from files'),
			_('Files on the router in the same format, for example /etc/mayhem/my.lst.'));
		o.modalonly = true;
		o.validate = function(section_id, value) {
			return (!value || /^\/\S+$/.test(value)) ? true : _('Expected an absolute path');
		};

		// --- advanced ---

		o = ss.option(form.Flag, '_more', _('Advanced settings'));
		o.modalonly = true;
		o.write = o.remove = function() {};
		o.cfgvalue = function(sid) {
			const g = (k) => this.map.data.get('mayhem', sid, k);

			return (g('proxy_type') === 'json' || g('filter') || g('exclude') || g('local_port') || L.toArray(g('iface_node')).length) ? '1' : '0';
		};

		o = ss.option(form.ListValue, 'proxy_type', _('Servers from'));
		o.value('link', _('Keys and subscriptions'));
		o.value('json', _('Xray outbound JSON'));
		o.default = 'link';
		o.depends({ type: 'proxy', _more: '1' });
		o.modalonly = true;
		keepHidden(o);

		o = ss.option(form.TextValue, 'outbound_json', _('Outbound JSON'),
			_('A single Xray outbound object. Its tag is replaced automatically.'));
		o.rows = 12;
		o.monospace = true;
		o.depends('type', 'proxy');
		o.modalonly = true;
		keepHidden(o);
		onJson(o, true);
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

		o = ss.option(form.Value, 'filter', _('Take servers named'),
			_('A regular expression over server names, case-insensitive. Example: NL|DE'));
		o.depends({ type: 'proxy', _more: '1' });
		o.modalonly = true;
		o.validate = validateRegexp;
		notJson(o);
		keepHidden(o);

		o = ss.option(form.Value, 'exclude', _('Skip servers named'));
		o.depends({ type: 'proxy', _more: '1' });
		o.modalonly = true;
		o.validate = validateRegexp;
		notJson(o);
		keepHidden(o);

		o = ss.option(widgets.NetworkSelect, 'iface_node', _('Tunnels as servers'),
			_('Network interfaces (AmneziaWG, WireGuard…) that join the servers of this section: the fastest one wins.'));
		o.multiple = true;
		o.nocreate = true;
		o.exclude = 'lan';
		o.depends({ type: 'proxy', _more: '1' });
		o.modalonly = true;
		notJson(o);
		keepHidden(o);

		o = ss.option(form.Value, 'local_port', _('Local proxy port'),
			_('A SOCKS5 and HTTP proxy on the router that sends everything into this section, for apps and devices that can use a proxy. Reachable from the LAN; the firewall closes it from the internet.'));
		o.datatype = 'range(1024,65535)';
		o.placeholder = _('Not used');
		o.depends({ type: 'proxy', _more: '1' });
		o.depends({ type: 'interface', _more: '1' });
		o.modalonly = true;
		keepHidden(o);

		o = ss.option(form.Value, 'local_user', _('Proxy user'), _('Empty: a proxy without a password.'));
		o.depends({ type: 'proxy', local_port: /.+/, _more: '1' });
		o.depends({ type: 'interface', local_port: /.+/, _more: '1' });
		o.modalonly = true;
		keepHidden(o);

		o = ss.option(form.Value, 'local_pass', _('Proxy password'));
		o.password = true;
		o.depends({ type: 'proxy', local_port: /.+/, _more: '1' });
		o.depends({ type: 'interface', local_port: /.+/, _more: '1' });
		o.modalonly = true;
		keepHidden(o);

		// Server options of a proxy section only matter with servers of its own.
		[ '_links', 'subscription', 'override', 'proxy_type', 'outbound_json', 'filter', 'exclude', 'iface_node' ].forEach((name) => {
			const opt = ss.children.find((c) => c.option === name);

			opt.deps = opt.deps.map((d) => d.type === 'proxy' ? Object.assign({}, d, { servers: 'own' }) : d);
		});

		// "pool" is the server list in the config.
		ss.handleAdd = function(ev, name) {
			if (name === 'pool') {
				ui.addNotification(null, E('p', _('The name "pool" is taken by the server list')), 'error');
				return Promise.resolve();
			}

			return form.GridSection.prototype.handleAdd.apply(this, arguments);
		};

		// --- grid columns ---

		o = ss.option(form.DummyValue, '_servers', _('Servers'));
		o.modalonly = false;
		o.textvalue = function(section_id) {
			const get = (k) => L.toArray(this.map.data.get('mayhem', section_id, k));
			const type = this.map.data.get('mayhem', section_id, 'type') || 'proxy';

			if (type === 'interface')
				return '%s (%s)'.format(this.map.data.get('mayhem', section_id, 'interface') || '?',
					this.map.data.get('mayhem', section_id, 'route_mode') === 'xray' ? _('Through Xray') : _('Kernel'));

			if (type !== 'proxy')
				return '—';

			if (!ownServers(this.map.data, section_id))
				return _('Server list');

			if (this.map.data.get('mayhem', section_id, 'proxy_type') === 'json')
				return 'JSON';

			const parts = [];
			const links = get('link').length;

			if (links)
				parts.push(_('Keys: %d').format(links));

			get('iface_node').forEach((n) => parts.push(n));
			get('subscription').forEach((n) => parts.push(n));

			return parts.join(', ') || _('No servers');
		};

		o = ss.option(form.DummyValue, '_rules', _('Rules'));
		o.modalonly = false;
		o.textvalue = function(section_id) {
			const d = L.toArray(this.map.data.get('mayhem', section_id, 'domain')).length;
			const i = L.toArray(this.map.data.get('mayhem', section_id, 'ip')).length;
			const l = L.toArray(this.map.data.get('mayhem', section_id, 'list_url')).length +
				L.toArray(this.map.data.get('mayhem', section_id, 'list_file')).length;
			const t = _('Domains: %d, addresses: %d').format(d, i);

			return l ? t + ', ' + _('lists: %d').format(l) : t;
		};

		// --- DNS ---

		s = m.section(form.NamedSection, 'dns', 'dns', _('DNS'),
			_('Direct traffic is resolved by the domestic DNS, proxied traffic by the remote DNS. The first server in a list is the main one, the next ones are fallbacks. Xray has no DNS over TLS: use https:// (DoH), tcp:// or a plain address.'));
		s.addremove = false;

		const lan = String(L.toArray(uci.get('network', 'lan', 'ipaddr'))[0] || '192.168.1.1').split('/')[0];

		o = s.option(form.DynamicList, 'domestic', _('Domestic DNS'),
			_('Empty, or the address of the router: the DNS servers of the provider.'));
		o.placeholder = lan;
		o.value('77.88.8.8', 'Yandex (77.88.8.8)');
		RESOLVERS.forEach((r) => o.value(r[1], '%s (%s)'.format(r[0], r[1])));

		o = s.option(form.DynamicList, 'remote', _('Remote DNS'));
		o.placeholder = _('Choose or type an address');
		RESOLVERS.forEach((r) => o.value(r[1], '%s (%s)'.format(r[0], r[1])));

		o = s.option(form.Flag, 'via_proxy', _('Remote DNS through the proxy'),
			now ? _('On: queries go through the active server, now %s. Off: they go direct, encrypted when the server is DoH.').format(now)
				: _('On: queries go through the active server. Off: they go direct, encrypted when the server is DoH.'));
		o.default = '1';
		o.rmempty = false;

		o = s.option(form.ListValue, 'ip_family', _('IP version'));
		o.ucisection = 'settings';
		o.value('prefer_ipv4', _('Prefer IPv4'));
		o.value('prefer_ipv6', _('Prefer IPv6'));
		o.value('ipv4_only', _('IPv4 only'));
		o.value('ipv6_only', _('IPv6 only'));
		o.default = 'prefer_ipv4';

		o = s.option(form.Flag, 'hijack', _('Intercept DNS on port 53'),
			_('Devices with their own DNS server (8.8.8.8 and others) get their answers from Mayhem as well.'));
		o.default = '1';
		o.rmempty = false;

		o = s.option(form.Flag, 'fakedns', _('FakeDNS'),
			_('Proxied domains get addresses from 198.18.0.0/15. Helps when an app hides the domain, but cached fake addresses stop working while Mayhem is stopped.'));

		// --- geo files ---

		s = m.section(form.NamedSection, 'geo', 'geo', _('Geo data'),
			_('Mayhem downloads the geosite and geoip files and reads them on the fly. Only the categories that sections use stay on the router, so a 70 MB file takes just a few hundred kilobytes of flash. New categories are downloaded within a minute after saving, the rest is updated every night.'));
		s.addremove = false;

		o = s.option(form.ListValue, 'update_hour', _('Nightly update time'));
		for (let h = 0; h < 24; h++)
			o.value(String(h), '%02d:00'.format(h));
		o.default = '4';

		o = s.option(form.Flag, 'via_xray', _('Download through Xray'),
			now ? _('Geo data and lists are downloaded through the active server, now %s; when that fails, direct.').format(now)
				: _('Geo data and lists are downloaded through the active server; when that fails, direct.'));
		o.default = '1';
		o.rmempty = false;
		o.cfgvalue = function(sid) {
			const v = this.map.data.get('mayhem', sid, 'via_xray');

			return v != null ? v : (this.map.data.get('mayhem', sid, 'update_via') === 'direct' ? '0' : '1');
		};

		o = s.option(form.ListValue, 'lists_interval', _('List updates'));
		o.value('6', _('Every 6 hours'));
		o.value('12', _('Every 12 hours'));
		o.value('24', _('Once a day'));
		o.value('72', _('Every 3 days'));
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
					: _('The update runs in the background. Open this tab again in a few minutes to see the result.')), 'info');
			});
		};

		o = s.option(form.SectionValue, '_sources', form.GridSection, 'geo_source', _('Geo data sources'),
			_('In sections a category is written as geosite:category or geosite:source:category. When several sources have the category, it is taken from the one higher in this list.'));
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
			_('A known source from the list, an https:// address of a .dat file or a path to a file on the router.'));
		o.rmempty = false;
		GEO_PRESETS.forEach((g) => o.value(g[2], '%s — %s'.format(g[1], g[0])));
		// A known source sets its type itself.
		o.write = function(sid, value) {
			const g = GEO_PRESETS.find((x) => x[2] === value);

			if (g)
				this.map.data.set('mayhem', sid, 'kind', g[0]);

			return form.Value.prototype.write.call(this, sid, value);
		};
		o.validate = function(section_id, value) {
			return (/^(https?:\/\/\S+|file:\/\/\/\S+|\/\S+)$/).test(value || '') ? true : _('Expected an http(s):// address or a file path');
		};

		o = s.option(form.DummyValue, '_state', _('State'));
		o.modalonly = false;
		o.textvalue = function(section_id) {
			const x = sourceInfo[section_id];

			if (this.map.data.get('mayhem', section_id, 'enabled') === '0')
				return E('span', { 'class': 'mh-muted' }, _('Turned off'));

			if (!x || x.categories == null)
				return x && x.error ? E('span', { 'class': 'mh-fail' }, x.error) : _('Not downloaded yet');

			if (x.error)
				return E('span', { 'class': 'mh-fail' }, x.error);

			return _('Categories: %d, in use: %d. Updated %s').format(x.categories, x.copied.length, since(x.updated));
		};

		return m.render().then((node) => {
			node.insertBefore(mh.style(), node.firstChild);

			if (!noGeo)
				return node;

			// Without a download there is no category list to pick from.
			const pane = node.querySelector('.cbi-section[data-tab="settings"]') || node;
			const btn = E('button', {
				'class': 'btn cbi-button-action',
				'click': ui.createHandlerFn(this, () => callDataUpdate('geo', '').then((r) => {
					ui.addNotification(null, E('p', r.busy ? _('An update is already running')
						: _('Geo data is downloading in the background. Open this page again in a few minutes.')), 'info');
				}))
			}, _('Download the category list'));

			pane.insertBefore(E('div', { 'class': 'cbi-section' }, [
				E('p', _('The geosite and geoip categories have not been downloaded yet.')), btn
			]), pane.firstChild);

			return node;
		});
	}
});
