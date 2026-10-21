'use strict';
'require baseclass';
'require form';
'require uci';
'require rpc';
'require ui';
'require dom';
'require tools.widgets as widgets';
'require mayhem.common as mh';

// Routing: the sections with their rules and the switches that apply to all
// traffic, DNS, geo files. A section opens in a dialog: type, servers, then
// rules (ready categories, own domains and addresses as text or as a list,
// rule lists); rarely needed options behind "Advanced settings".

const callHostHints = rpc.declare({ object: 'luci-rpc', method: 'getHostHints', expect: { '': {} } });
const callGeo = rpc.declare({ object: 'luci.mayhem', method: 'geo', expect: { '': {} } });
const callDataUpdate = rpc.declare({ object: 'luci.mayhem', method: 'data_update', params: [ 'what', 'name' ], expect: { '': {} } });
const callGeoImport = rpc.declare({ object: 'luci.mayhem', method: 'geo_import', params: [ 'name', 'kind' ], expect: { '': {} } });
const callDashboard = rpc.declare({ object: 'luci.mayhem', method: 'dashboard', expect: { '': {} } });
const callRename = rpc.declare({ object: 'luci.mayhem', method: 'rename_section', params: [ 'name', 'new_name' ], expect: { '': {} } });

const ROUTE_KERNEL = _('Kernel is the fastest: traffic goes into the tunnel straight from the kernel, without Xray. The best choice for games and calls. Domains, GeoSite, GeoIP and subnets work; keyword and regexp rules only work through the Xray backup. Kernel sections always go before the other sections.');
const ROUTE_XRAY = _('Through Xray is more flexible: every rule works. Speed is limited by Xray.');

// Categories above this make xray use a lot of memory (same limit as the generator).
const HEAVY = 50000;

// Popular resolvers: [ id, name, plain address (UDP and TCP), DoH address,
// DoQ address ]. Comss and Xbox DNS only answer over DoH; of these only
// AdGuard answers over QUIC.
const PROVIDERS = [
	[ 'cloudflare', 'Cloudflare', '1.1.1.1', 'https://1.1.1.1/dns-query', null ],
	[ 'google', 'Google', '8.8.8.8', 'https://8.8.8.8/dns-query', null ],
	[ 'quad9', 'Quad9', '9.9.9.9', 'https://9.9.9.9/dns-query', null ],
	[ 'adguard', 'AdGuard', '94.140.14.14', 'https://dns.adguard-dns.com/dns-query', 'quic://dns.adguard-dns.com' ],
	[ 'yandex', 'Yandex', '77.88.8.8', 'https://common.dot.dns.yandex.net/dns-query', null ],
	[ 'comss', 'Comss DNS', null, 'https://dns.comss.one/dns-query', null ],
	[ 'xbox', 'Xbox DNS', null, 'https://xbox-dns.ru/dns-query', null ]
];

// DoQ: Xray asks it directly only, past the proxy and the tunnels.
const DNS_TYPES = [ [ 'udp', 'UDP' ], [ 'tcp', 'TCP' ], [ 'doh', 'DoH (HTTPS)' ], [ 'doq', _('DoQ (QUIC, direct)') ] ];

// A DNS server as written in the config -> [ type, address as shown ].
function dnsSplit(v) {
	v = String(v || '').trim();

	if (/^https:\/\//i.test(v))
		return [ 'doh', v ];

	if (/^(quic|doq):\/\//i.test(v))
		return [ 'doq', v.replace(/^doq:\/\//i, 'quic://') ];

	if (/^tcp:\/\//i.test(v))
		return [ 'tcp', v.replace(/^tcp:\/\//i, '') ];

	return [ 'udp', v.replace(/^udp:\/\//i, '') ];
}

// [ type, address ] -> the config form: 1.1.1.1, tcp://1.1.1.1:53,
// https://1.1.1.1/dns-query (a bare host becomes a DoH URL with /dns-query),
// quic://dns.adguard-dns.com.
function dnsJoin(type, addr) {
	addr = String(addr || '').trim();

	if (!addr)
		return '';

	if (type === 'doh') {
		if (/^https:\/\//i.test(addr))
			return addr;

		const host = addr.replace(/^[a-z]+:\/\//i, '').replace(/\/.*$/, '');

		return 'https://' + host + '/dns-query';
	}

	addr = addr.replace(/^[a-z+]+:\/\//i, '').replace(/\/.*$/, '');

	return type === 'tcp' ? 'tcp://' + addr : type === 'doq' ? 'quic://' + addr : addr;
}

function provider(id) {
	return PROVIDERS.find((p) => p[0] === id) || null;
}

// A server of the config -> what the drop-down shows: a provider or the address.
function dnsChoice(v) {
	const sp = dnsSplit(v);
	const plain = sp[1].replace(/:53$/, '');
	const p = PROVIDERS.find((x) => sp[0] === 'doh' ? x[3] === sp[1] : sp[0] === 'doq' ? x[4] === sp[1] : x[2] === plain);

	return p ? p[0] : sp[1];
}

// A choice of the drop-down with the common type -> the config form.
function dnsEntry(type, choice) {
	const p = provider(choice);

	if (!p)
		return dnsJoin(type, choice);

	return type === 'doh' ? p[3] : type === 'doq' ? (p[4] || '') : (p[2] ? dnsJoin(type, p[2]) : '');
}

// A resolver that does not answer over the chosen type: why, or null.
function dnsMismatch(type, p) {
	if (type === 'doq' && !p[4])
		return _('%s does not answer over DoQ').format(p[1]);

	if ((type === 'udp' || type === 'tcp') && !p[2])
		return _('%s only works over DoH').format(p[1]);

	return null;
}

// Servers of a DNS list are the items of a dynamic list: the order of the
// items is the order they are asked in, and an item is dragged to another
// place with the mouse or a finger. The item's text lets the drop through to
// the item itself, so a server dropped on a name lands before it rather
// than at the end.
const DnsList = form.DynamicList.extend({
	__name__: 'CBI.MayhemDnsList',

	renderWidget(section_id, option_index, cfgvalue) {
		const node = this.super('renderWidget', [ section_id, option_index, cfgvalue ]);

		node.classList.add('mh-dns-dynlist');

		return node;
	}
});

// The type and the servers of a DNS list: the global ones (section "dns") or
// those of a routing section. Both options write the same UCI list.
function dnsOptions(s, kind, labels, defType) {
	const typeName = '_' + kind + '_type';
	const list = (o, sid) => L.toArray(o.map.data.get('mayhem', sid, kind));
	// In a section's dialog the options are copies bound to the dialog's
	// section: they are asked through this.section, not s.
	const typeOf = (o, sid) => o.section.formvalue(sid, typeName) || defType;

	const store = function(sid) {
		const t = typeOf(this, sid);
		const all = L.toArray(this.section.formvalue(sid, kind)).map((x) => dnsEntry(t, x)).filter((x) => x);

		if (all.length)
			this.map.data.set('mayhem', sid, kind, all);
		else
			this.map.data.unset('mayhem', sid, kind);

		// The type is kept even without servers: chosen first, the servers later.
		if (t !== defType || this.map.data.get('mayhem', sid, kind + '_type'))
			this.map.data.set('mayhem', sid, kind + '_type', t);
	};

	let o = s.option(form.ListValue, typeName, labels[0]);
	DNS_TYPES.forEach((t) => o.value(t[0], t[1]));
	o.cfgvalue = function(sid) {
		const l = list(this, sid);

		return l.length ? dnsSplit(l[0])[0] : (this.map.data.get('mayhem', sid, kind + '_type') || defType);
	};
	o.write = o.remove = store;
	// Saved as its own value, so that a type chosen alone is saved too.
	o.forcewrite = true;
	const typeOpt = o;

	o = s.option(DnsList, kind, labels[1], labels[2]);
	PROVIDERS.forEach((p) => o.value(p[0], p[2] ? '%s (%s)'.format(p[1], p[2]) : '%s (DoH)'.format(p[1])));
	o.cfgvalue = function(sid) {
		return list(this, sid).map(dnsChoice);
	};
	// A server added to the list is checked as it is added; the whole list
	// once more on saving, as the type may have changed since.
	const mismatch = (o, sid, values) => {
		for (const x of L.toArray(values)) {
			const p = provider(x);
			const why = p ? dnsMismatch(typeOf(o, sid), p) : null;

			if (why)
				return why;
		}

		return true;
	};
	o.validate = function(sid, v) {
		return mismatch(this, sid, v);
	};
	o.isValid = function(sid) {
		this.listError = this.isActive(sid) ? mismatch(this, sid, this.formvalue(sid)) : true;

		return this.listError === true && form.DynamicList.prototype.isValid.call(this, sid);
	};
	o.getValidationError = function(sid) {
		return this.listError !== true && this.listError != null ? this.listError
			: form.DynamicList.prototype.getValidationError.call(this, sid);
	};
	o.write = o.remove = store;
	o.typeOption = typeOpt;

	return o;
}

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
// A key, or a server kept as Xray JSON on one line.
const LINK_RE = /^((vless|vmess|trojan|ss|socks5?|https?|hysteria2|hy2|wireguard|wg):\/\/\S+|\{.*\}$)/i;

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
// Well-known categories, offered until the router has the list of its source.
const GEO_COMMON = {
	geosite: [ 'ru-blocked', 'ru-blocked-all', 'youtube', 'google', 'telegram', 'discord', 'twitter', 'facebook', 'instagram', 'openai', 'category-ads-all' ],
	geoip: [ 'ru-blocked', 'ru', 'telegram', 'google', 'facebook', 'twitter', 'private' ]
};

function geoChoices(o, kind, cats) {
	const seen = {};

	// Without a downloaded list the field is still a drop-down: the common
	// categories, and anything else can be typed in.
	if (!cats.length) {
		for (const c of GEO_COMMON[kind])
			o.value('%s:%s'.format(kind, c));

		return;
	}

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

return baseclass.extend({
	load() {
		return Promise.all([
			uci.load([ 'mayhem', 'network' ]),
			L.resolveDefault(callGeo(), {}),
			L.resolveDefault(callDashboard(), {}),
			L.resolveDefault(callHostHints(), {})
		]);
	},

	render(data) {
		const hosts = data[3] || {};
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

		// A kernel tunnel as the main section takes the rest in the kernel.
		const mainSec = uci.get('mayhem', 'settings', 'default_section');
		const kernelMain = mainSec && uci.get('mayhem', mainSec, 'type') === 'interface' &&
			(uci.get('mayhem', mainSec, 'route_mode') || 'kernel') === 'kernel';

		o = s.option(form.Flag, 'mode', _('Global mode'),
			(now ? _('Traffic that matches no rule goes through the active server, now %s. When this is off, it goes direct.').format(now)
				: _('Traffic that matches no rule goes through the active server. When this is off, it goes direct.')) +
			(kernelMain ? ' ' + _('The main section is a tunnel in kernel mode: the rest goes into it in the kernel, past Xray. Exclusions and proxy sections by domain need dnsmasq-full. With torrents direct, only web traffic goes into it in the kernel, the rest through Xray.') : ''));
		o.enabled = 'global';
		o.disabled = 'lists';
		o.default = 'lists';
		o.rmempty = false;

		o = s.option(form.Flag, 'exclude_local', _('Bypass local networks'),
			_('Addresses of local networks (10.0.0.0/8, 192.168.0.0/16 and others) always go direct.'));
		o.default = '1';
		o.rmempty = false;

		o = s.option(form.Flag, 'block_quic', _('Block QUIC (UDP/443)'),
			_('Browsers and apps fall back from QUIC (UDP 443) to TCP, which works better through a proxy.'));
		o.rmempty = false;

		o = s.option(form.Flag, 'torrent_direct', _('BitTorrent bypass'),
			_('Xray recognizes BitTorrent by its first packets and sends it direct, past the proxy.'));
		o.rmempty = false;

		o = s.option(form.Flag, 'killswitch', _('KillSwitch'),
			_('On: when the servers or the remote DNS do not answer, traffic waits for them and never goes direct; so does it while Xray restarts. Off: a section none of whose servers answers sends its traffic direct (with a fallback chain - only when every server of the chain is down), and names of the remote DNS go to the provider\'s DNS while it does not answer; everything comes back by itself when they answer again.'));
		o.rmempty = false;

		o = s.option(form.DynamicList, 'bypass', _('Excluded source IP/MAC'),
			_('Traffic and DNS of these devices are left alone, in any mode: for a work laptop with a VPN of its own, a game console and the like. An IP address, a subnet or a MAC address. Only addresses from 198.18.0.0/15 still go to Xray, which the router\'s DNS gives out for proxied sites.'));
		o.datatype = 'or(macaddr,cidr,ipaddr)';
		o.placeholder = _('IP or MAC address');
		Object.keys(hosts).sort().forEach((mac) => {
			const h = hosts[mac] || {};
			const ip = L.toArray(h.ipaddrs || h.ipv4)[0];
			const label = h.name ? '%s (%s)'.format(h.name, ip || mac) : (ip ? '%s (%s)'.format(ip, mac) : mac);

			o.value(mac, label);
		});

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

		o = ss.option(form.ListValue, 'type', _('Section type'),
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
		o = ss.option(form.ListValue, 'servers', _('Connection'),
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

		o = ss.option(form.TextValue, '_links', _('Proxy URLs'),
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

		// LuCI's dropdown throws on an empty choice list: without subscriptions
		// the field is only a hint and leaves the option as it is.
		if (subs.length) {
			o = ss.option(form.MultiValue, 'subscription', _('Subscriptions'),
				_('Servers of these subscriptions are added to the section.'));
			subs.forEach((n) => o.value(n));
			keepHidden(o);
		}
		else {
			o = ss.option(form.DummyValue, 'subscription', _('Subscriptions'));
			o.cfgvalue = () => _('No subscriptions yet: add them with the "Add connection" button.');
		}
		o.depends('type', 'proxy');
		notJson(o);
		o.modalonly = true;

		o = ss.option(form.ListValue, 'override', _('Default outbound'),
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

		o = ss.option(widgets.NetworkSelect, 'interface', _('Network interface'),
			_('The network interface of the tunnel. When the tunnel stops working (no handshake for 3 minutes), its traffic goes direct until it is back.'));
		o.nocreate = true;
		o.exclude = 'lan';
		o.depends('type', 'interface');
		o.modalonly = true;

		o = ss.option(form.ListValue, 'route_mode', _('Routing backend'), ROUTE_KERNEL + '<br>' + ROUTE_XRAY);
		o.value('kernel', _('Kernel (fastest)'));
		o.value('xray', _('Through Xray'));
		o.default = 'kernel';
		o.depends('type', 'interface');
		o.modalonly = true;

		// --- ports of a direct section ---

		o = ss.option(form.DynamicList, 'ports', _('Bypass ports'),
			_('TCP and UDP traffic to these destination ports goes past the routing to any address. A port or a range of ports. The domains and addresses of the section are excluded on any port.'));
		o.datatype = 'or(port,portrange)';
		o.depends('type', 'exclusion');
		o.modalonly = true;

		// --- who ---

		// Some devices only; none: the whole network. Other devices go on to
		// the sections below.
		o = ss.option(form.DynamicList, 'devices', _('Source IP/MAC'),
			_('Empty: the whole network. Other devices go on to the sections below, as if this one did not exist. Xray tells devices by their address: a device given by MAC needs a lease (best a static one, under DHCP and DNS → Static leases).'));
		o.datatype = 'or(macaddr,cidr,ipaddr)';
		o.placeholder = _('The whole network');
		o.depends('type', 'proxy');
		o.depends('type', 'interface');
		o.modalonly = true;
		Object.keys(hosts).sort().forEach((mac) => {
			const h = hosts[mac] || {};
			const ip = L.toArray(h.ipaddrs || h.ipv4)[0];
			const label = h.name ? '%s (%s)'.format(h.name, ip || mac) : (ip ? '%s (%s)'.format(ip, mac) : mac);

			o.value(mac, label);
		});

		// --- rules ---

		// Domains and addresses apart: geosite categories, then geoip ones.
		const heavyNote = _('Categories marked as heavy hold more than %s rules and make Xray use a lot of memory.').format(formatCount(HEAVY)) +
			(noGeo ? ' ' + _('Categories appear in the list after the first geo data download.') : '');

		o = ss.option(form.DynamicList, '_sites', _('GeoSite categories'), heavyNote);
		o.placeholder = _('Choose');
		o.modalonly = true;
		geoChoices(o, 'geosite', cats.geosite);
		o.cfgvalue = function(sid) {
			return list(this, sid, 'domain').filter(isGeo);
		};
		o.validate = function(sid, value) {
			return (!value || GEOSITE_RE.test(value)) ? true : _('Expected geosite:category');
		};
		viewOf(o, 'list', function(sid, value) {
			setList(this, sid, 'domain', list(this, sid, 'domain').filter((x) => !isGeo(x)).concat(L.toArray(value)));
		});

		o = ss.option(form.DynamicList, '_geoips', _('GeoIP categories'));
		o.placeholder = _('Choose');
		o.modalonly = true;
		geoChoices(o, 'geoip', cats.geoip);
		o.cfgvalue = function(sid) {
			return list(this, sid, 'ip').filter(isGeo);
		};
		o.validate = function(sid, value) {
			return (!value || GEOIP_RE.test(value)) ? true : _('Expected geoip:category');
		};
		viewOf(o, 'list', function(sid, value) {
			setList(this, sid, 'ip', list(this, sid, 'ip').filter((x) => !isGeo(x)).concat(L.toArray(value)));
		});

		o = ss.option(form.ListValue, 'rules_input', _('User list input type'));
		o.value('text', _('As text'));
		o.value('list', _('As a list'));
		o.default = 'text';
		o.modalonly = true;

		o = ss.option(form.TextValue, '_text', _('User domains'),
			_('One per line, or separated by commas or spaces; "#" starts a comment. example.com matches the domain and its subdomains; full: is the exact name, keyword: a substring, regexp: a regular expression.'));
		o.rows = 6;
		o.monospace = true;
		o.depends('rules_input', 'text');
		o.modalonly = true;
		o.cfgvalue = function(sid) {
			return list(this, sid, 'domain').filter((x) => !isGeo(x)).join('\n');
		};
		o.validate = function(sid, value) {
			for (const t of tokens(value)) {
				if (isIp(t))
					return _('%s is an address: it goes into the field below').format(t);

				const e = domainError(t);

				if (e)
					return e;
			}

			return true;
		};
		viewOf(o, 'text', function(sid, value) {
			setList(this, sid, 'domain', list(this, sid, 'domain').filter(isGeo).concat(tokens(value)));
		});

		o = ss.option(form.TextValue, '_text_ip', _('User subnets'),
			_('IPv4 or IPv6 addresses, CIDR allowed, one per line or separated by commas or spaces: 91.108.4.0/22, 2001:db8::/32.'));
		o.rows = 4;
		o.monospace = true;
		o.depends('rules_input', 'text');
		o.modalonly = true;
		o.cfgvalue = function(sid) {
			return list(this, sid, 'ip').filter((x) => !isGeo(x)).join('\n');
		};
		o.validate = function(sid, value) {
			for (const t of tokens(value))
				if (!isIp(t))
					return _('Expected an IP address or a subnet in CIDR form') + ': ' + t;

			return true;
		};
		viewOf(o, 'text', function(sid, value) {
			setList(this, sid, 'ip', list(this, sid, 'ip').filter(isGeo).concat(tokens(value)));
		});

		o = ss.option(form.DynamicList, '_domains', _('User domains'),
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

		o = ss.option(form.DynamicList, '_ips', _('User subnets'),
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

		o = ss.option(form.DynamicList, 'list_url', _('Remote lists'),
			_('Text lists with one domain, rule or subnet per line, "#" for comments. They are downloaded and updated automatically.'));
		o.modalonly = true;
		o.validate = function(section_id, value) {
			return (!value || /^https?:\/\/\S+$/.test(value)) ? true : _('Expected an http(s):// address');
		};

		o = ss.option(form.DynamicList, 'list_file', _('Local lists'),
			_('Files on the router in the same format, for example /etc/mayhem/my.lst.'));
		o.modalonly = true;
		o.validate = function(section_id, value) {
			return (!value || /^\/\S+$/.test(value)) ? true : _('Expected an absolute path');
		};

		// --- DNS of the section ---

		o = dnsOptions(ss, 'dns', [ _('DNS protocol'), _('DNS servers'),
			_('Empty: the DNS of the DNS tab. The names of this section are asked here, through the section itself, in order: the first one is the main server. A proxy section with FakeDNS needs none: its server resolves the names.') ], 'udp');
		o.placeholder = _('The DNS of the DNS tab');
		o.modalonly = true;
		o.depends('type', 'proxy');
		o.depends('type', 'interface');
		o.depends('type', 'exclusion');
		o.typeOption.modalonly = true;
		o.typeOption.depends('type', 'proxy');
		o.typeOption.depends('type', 'interface');
		o.typeOption.depends('type', 'exclusion');

		// --- advanced ---

		o = ss.option(form.Flag, '_more', _('Advanced'));
		o.modalonly = true;
		// Only proxy and tunnel sections have advanced options.
		o.depends('type', 'proxy');
		o.depends('type', 'interface');
		o.write = o.remove = function() {};
		o.cfgvalue = function(sid) {
			const g = (k) => this.map.data.get('mayhem', sid, k);

			return (g('proxy_type') === 'json' || g('filter') || g('exclude') || g('local_port') || L.toArray(g('iface_node')).length) ? '1' : '0';
		};

		o = ss.option(form.ListValue, 'proxy_type', _('Configuration type'));
		o.value('link', _('Keys and subscriptions'));
		o.value('json', _('Xray outbound JSON'));
		o.default = 'link';
		o.depends({ type: 'proxy', _more: '1' });
		o.modalonly = true;
		keepHidden(o);

		o = ss.option(form.TextValue, 'outbound_json', _('Outbound configuration (JSON)'),
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

		o = ss.option(form.Value, 'filter', _('Name filter (regexp)'),
			_('A regular expression over server names, case-insensitive. Example: NL|DE'));
		o.depends({ type: 'proxy', _more: '1' });
		o.modalonly = true;
		o.validate = validateRegexp;
		notJson(o);
		keepHidden(o);

		o = ss.option(form.Value, 'exclude', _('Name exclusion (regexp)'));
		o.depends({ type: 'proxy', _more: '1' });
		o.modalonly = true;
		o.validate = validateRegexp;
		notJson(o);
		keepHidden(o);

		o = ss.option(widgets.NetworkSelect, 'iface_node', _('Interface outbounds'),
			_('Network interfaces (AmneziaWG, WireGuard…) that join the servers of this section: the fastest one wins.'));
		o.multiple = true;
		o.nocreate = true;
		o.exclude = 'lan';
		o.depends({ type: 'proxy', _more: '1' });
		o.modalonly = true;
		notJson(o);
		keepHidden(o);

		o = ss.option(form.Value, 'local_port', _('Mixed proxy port'),
			_('A SOCKS5 and HTTP proxy on the router that sends everything into this section, for apps and devices that can use a proxy. Reachable from the LAN; the firewall closes it from the internet.'));
		o.datatype = 'range(1024,65535)';
		o.placeholder = _('Not used');
		o.depends({ type: 'proxy', _more: '1' });
		o.depends({ type: 'interface', _more: '1' });
		o.modalonly = true;
		keepHidden(o);

		o = ss.option(form.Value, 'local_user', _('Mixed proxy user'), _('Empty: a proxy without a password.'));
		o.depends({ type: 'proxy', local_port: /.+/, _more: '1' });
		o.depends({ type: 'interface', local_port: /.+/, _more: '1' });
		o.modalonly = true;
		keepHidden(o);

		o = ss.option(form.Value, 'local_pass', _('Mixed proxy password'));
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
			_('Direct traffic is resolved by the domestic DNS. Domains of proxy sections get addresses from Xray itself and are resolved by the proxy server; the remote DNS serves tunnel sections and the rest of the traffic when everything goes through the proxy. The main server and its fallbacks share one type: UDP, TCP, DoH or DoQ (Xray has no DNS over TLS; DoQ always goes direct).'));
		s.addremove = false;

		const lan = String(L.toArray(uci.get('network', 'lan', 'ipaddr'))[0] || '192.168.1.1').split('/')[0];

		o = dnsOptions(s, 'domestic', [ _('Domestic DNS protocol'), _('Domestic DNS servers'),
			_('Add one or several from the list or type your own address. They are asked in the order of the list: the first one is the main server, the next ones are fallbacks. Drag a server to change the order. None: the DNS servers of the provider.') ], 'udp');
		o.placeholder = lan;

		o = dnsOptions(s, 'remote', [ _('Remote DNS protocol'), _('Remote DNS servers'),
			_('Add one or several from the list or type your own address. They are asked in the order of the list: the first one is the main server, the next ones are fallbacks. Drag a server to change the order.') ], 'doh');
		o.placeholder = _('Choose or type an address');

		// Xray does not ask a DoH server again when its answer breaks off:
		// with one server the device gets an error.
		if (L.toArray(uci.get('mayhem', 'dns', 'remote')).length === 1)
			o.description += ' ' + _('With one server, a query it fails to answer fails on the device too: add a second one, Cloudflare or Google say, to take over.');

		o = s.option(form.Flag, 'parallel', _('Parallel queries'),
			_('On: every server of a list gets the query together and the first good answer counts, which is faster when one of them is slow. Off: the next server only when the one before fails.'));

		o = s.option(form.Flag, 'via_proxy', _('Remote DNS via proxy'),
			now ? _('On: queries go through the active server, now %s. Off: they go direct, encrypted when the server is DoH.').format(now)
				: _('On: queries go through the active server. Off: they go direct, encrypted when the server is DoH.'));
		o.default = '1';
		o.rmempty = false;

		o = s.option(form.ListValue, 'ip_family', _('Query strategy'));
		o.ucisection = 'settings';
		o.value('prefer_ipv4', _('Prefer IPv4'));
		o.value('prefer_ipv6', _('Prefer IPv6'));
		o.value('ipv4_only', _('IPv4 only'));
		o.value('ipv6_only', _('IPv6 only'));
		o.default = 'prefer_ipv4';

		o = s.option(form.Flag, 'hijack', _('DNS hijack (port 53)'),
			_('Devices with their own DNS server (8.8.8.8 and others) get their answers from Mayhem as well.'));
		o.default = '1';
		o.rmempty = false;

		o = s.option(form.Flag, 'fakedns', _('FakeDNS'),
			_('Only matters in global mode: domains get addresses from 198.18.0.0/15 (without it, they are recognized by their TLS name), and the traffic of excluded domains goes direct in the kernel, past Xray (needs dnsmasq-full). By lists, Xray always does this. Cached fake addresses stop working while Mayhem is stopped.'));

		// --- geo files ---

		s = m.section(form.NamedSection, 'geo', 'geo', _('Geo data'),
			_('Mayhem downloads the GeoSite and GeoIP files and reads them on the fly. Only the categories that sections use stay on the router, so a 70 MB file takes just a few hundred kilobytes of flash. New categories are downloaded within a minute after saving, the rest is updated every night.'));
		s.addremove = false;

		o = s.option(form.ListValue, 'update_hour', _('Update hour'));
		for (let h = 0; h < 24; h++)
			o.value(String(h), '%02d:00'.format(h));
		o.default = '4';

		o = s.option(form.Flag, 'via_xray', _('Download via proxy'),
			now ? _('Geo data and lists are downloaded through the active server, now %s; when that fails, direct.').format(now)
				: _('Geo data and lists are downloaded through the active server; when that fails, direct.'));
		o.default = '1';
		o.rmempty = false;
		o.cfgvalue = function(sid) {
			const v = this.map.data.get('mayhem', sid, 'via_xray');

			return v != null ? v : (this.map.data.get('mayhem', sid, 'update_via') === 'direct' ? '0' : '1');
		};

		o = s.option(form.ListValue, 'lists_interval', _('Lists update interval'));
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
					: _('The update runs in the background. Open this window again in a few minutes to see the result.')), 'info');
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

		o = s.option(form.ListValue, 'kind', _('Section type'));
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
						: _('Geo data is downloading in the background. Open this window again in a few minutes.')), 'info');
				}))
			}, _('Download the category list'));

			pane.insertBefore(E('div', { 'class': 'cbi-section' }, [
				E('p', _('The GeoSite and GeoIP categories have not been downloaded yet.')), btn
			]), pane.firstChild);

			return node;
		});
	}
});
