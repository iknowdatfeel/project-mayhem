// Mayhem: builds the Xray config, the nftables ruleset and the dnsmasq snippet
// from a configuration model. Pure function: no file or system access, so it
// can be tested off-device. See model.uc for how the model is read from UCI.

'use strict';

import { parse_link, outbound_host, outbound_port, outbound_udp, refused_by_xray } from 'mayhem.links';
import { is_true, entries, norm_domain, norm_ip, is_ip, dns_server, split_list, list_key } from 'mayhem.rules';
import { resolve, HEAVY } from 'mayhem.geo';
import * as C from 'mayhem.const';

const LOG_LEVELS = [ 'debug', 'info', 'warning', 'error', 'none' ];

const FAMILY = {
	prefer_ipv4: { dns: 'UseIP', freedom: 'UseIPv4v6', sockopt: 'UseIPv4v6' },
	prefer_ipv6: { dns: 'UseIP', freedom: 'UseIPv6v4', sockopt: 'UseIPv6v4' },
	ipv4_only: { dns: 'UseIPv4', freedom: 'ForceIPv4', sockopt: 'UseIPv4' },
	ipv6_only: { dns: 'UseIPv6', freedom: 'ForceIPv6', sockopt: 'UseIPv6' }
};

const SERVICE_PROTOCOLS = [ 'freedom', 'direct', 'blackhole', 'block', 'dns', 'loopback' ];

// dnsmasq asks every query from a new source port, and xray keeps each such
// UDP session open for connIdle (300 s by default) with a few goroutines:
// about a thousand idle DNS sessions on a home network, 20-30 MB of RAM.
// DNS sessions get their own level with a short idle timeout. An answer takes
// a few seconds at most, and xray closes a session between one and two
// timeouts after its last packet.
const DNS_LEVEL = 1;
const DNS_IDLE = 10;

function int_opt(v, def, min, max) {
	if (v == null || v == '' || !match(`${v}`, /^-?[0-9]+$/))
		return def;

	const n = int(v);

	return (n < min || n > max) ? def : n;
}

function uniq_push(arr, v) {
	if (index(arr, v) < 0)
		push(arr, v);
}

// Append-only list without duplicates; lists from geo data and downloaded
// rule lists hold tens of thousands of entries, so lookups go through a map.
function uset() {
	return {
		items: [], seen: {},

		add: function(v) {
			if (!this.seen[v]) {
				this.seen[v] = true;
				push(this.items, v);
			}
		},

		add_all: function(arr) {
			for (let v in arr)
				this.add(v);
		}
	};
}

// User-supplied outbound JSON: a single outbound object, an array of them,
// or a whole client config with "outbounds".
function json_outbound(text) {
	let j;

	try {
		j = json(text);
	}
	catch (e) {
		die('outbound JSON is not valid JSON');
	}

	if (type(j) == 'object' && type(j.outbounds) == 'array')
		j = j.outbounds;

	if (type(j) == 'array')
		j = filter(j, (o) => type(o) == 'object' && index(SERVICE_PROTOCOLS, o.protocol) < 0)[0];

	if (type(j) != 'object' || type(j.protocol) != 'string')
		die('outbound JSON has no "protocol"');

	delete j.tag;

	return j;
}

function apply_sockopt(ob, strategy) {
	if (ob.protocol == 'wireguard')
		return;

	if (ob.streamSettings?.sockopt?.interface && ob.streamSettings.sockopt.domainStrategy == null) {
		ob.streamSettings.sockopt.domainStrategy = strategy;
		return;
	}

	ob.streamSettings ??= {};
	ob.streamSettings.sockopt ??= {};
	ob.streamSettings.sockopt.domainStrategy ??= strategy;
}

function apply_mux(ob, S) {
	if (ob.protocol != 'vless' || ob.mux != null || !is_true(S.mux))
		return;

	const vision = match(ob.settings?.flow ?? '', /^xtls-rprx-vision/);

	ob.mux = {
		enabled: true,
		// Vision cannot carry TCP inside Mux: only UDP goes through XUDP.
		concurrency: vision ? -1 : int_opt(S.mux_concurrency, 8, 1, 1024),
		xudpConcurrency: int_opt(S.mux_xudp_concurrency, 16, 1, 1024),
		xudpProxyUDP443: S.mux_xudp_udp443 ?? 'reject'
	};
}

function nft_set(name, ftype, elems) {
	let s = `\tset ${name} {\n\t\ttype ${ftype}\n\t\tflags interval\n\t\tauto-merge\n`;

	if (length(elems)) {
		s += '\t\telements = {';

		// geoip sets have thousands of subnets: a few per line keeps lines short.
		for (let i = 0; i < length(elems); i += 8)
			s += `${i ? ',' : ''}\n\t\t\t${join(', ', slice(elems, i, i + 8))}`;

		s += '\n\t\t}\n';
	}

	return s + '\t}\n';
}

// Marks for tunnel sections in kernel mode: TUN_MARK | index, matched with
// TUN_MASK, so other users of the mark (fw4, mwan3) keep their bits.
function tun_mark(idx) {
	return sprintf('0x%x', C.TUN_MARK | idx);
}

function build_nft(S, v6, sets, tunnels, dns_redirect, fake_pool) {
	const ifaces = map(length(sets.ifaces) ? sets.ifaces : [ 'br-lan' ], (i) => sprintf('%J', i));
	const mark = sprintf('0x%x', C.FWMARK);
	const keep = sprintf('0x%x', 0xffffffff & ~C.TUN_MASK);
	let s = `table inet ${C.NFT_TABLE}\ndelete table inet ${C.NFT_TABLE}\n\n`;

	s += `table inet ${C.NFT_TABLE} {\n`;
	s += `\tset ifaces {\n\t\ttype ifname\n\t\telements = { ${join(', ', ifaces)} }\n\t}\n`;
	// Local addresses stay on the router; without the option only what can
	// never be routed (loopback, link-local, multicast) is left out.
	const local = is_true(S.exclude_local ?? '1');

	s += nft_set('local4', 'ipv4_addr', local ? C.LOCAL4 : C.LOCAL4_ALWAYS);
	s += nft_set('local6', 'ipv6_addr', local ? C.LOCAL6 : C.LOCAL6_ALWAYS);
	s += nft_set('block4', 'ipv4_addr', sets.block4);
	s += nft_set('block6', 'ipv6_addr', sets.block6);
	s += nft_set('direct4', 'ipv4_addr', sets.direct4);
	s += nft_set('direct6', 'ipv6_addr', sets.direct6);

	// Tunnel sections in kernel mode: subnets from the rules, plus addresses
	// that dnsmasq adds while it resolves the section's domains.
	for (let t in tunnels) {
		s += nft_set(`tun_${t.name}_4`, 'ipv4_addr', t.ip4);
		s += nft_set(`tun_${t.name}_6`, 'ipv6_addr', t.ip6);
		s += `\tset tun_${t.name}_d4 {\n\t\ttype ipv4_addr\n\t}\n`;
		s += `\tset tun_${t.name}_d6 {\n\t\ttype ipv6_addr\n\t}\n`;
	}

	s += '\n\tchain prerouting {\n';
	s += '\t\ttype filter hook prerouting priority mangle; policy accept;\n';

	// The router's own connections to FakeDNS addresses (chain output) come
	// back through lo with the mark.
	if (fake_pool)
		s += `\t\tiifname "lo" meta mark & ${mark} == ${mark} ip daddr ${fake_pool} meta l4proto { tcp, udp } tproxy ip to 127.0.0.1:${C.TPROXY_PORT} counter accept\n`;

	s += '\t\tiifname != @ifaces return\n';
	s += '\t\tfib daddr type { local, broadcast, multicast } return\n';
	s += '\t\tip daddr @local4 return\n';
	s += '\t\tip6 daddr @local6 return\n';
	s += '\t\tip daddr @block4 counter drop\n';
	s += '\t\tip6 daddr @block6 counter drop\n';

	// Kernel tunnels go before everything else: the mark selects their
	// routing table, and the packet never reaches xray.
	for (let t in tunnels) {
		const m = `meta mark set meta mark & ${keep} | ${tun_mark(t.index)}`;

		s += `\t\tip daddr @tun_${t.name}_4 ${m} counter return\n`;
		s += `\t\tip daddr @tun_${t.name}_d4 ${m} counter return\n`;
		s += `\t\tip6 daddr @tun_${t.name}_6 ${m} counter return\n`;
		s += `\t\tip6 daddr @tun_${t.name}_d6 ${m} counter return\n`;
	}

	s += '\t\tmeta l4proto != { tcp, udp } return\n';

	// DNS goes to dnsmasq (chain dstnat) so that it fills the tunnel sets.
	if (dns_redirect)
		s += '\t\tth dport 53 return\n';

	s += '\t\tip daddr @direct4 counter return\n';
	s += '\t\tip6 daddr @direct6 counter return\n';
	s += `\t\tmeta nfproto ipv4 meta l4proto { tcp, udp } meta mark set meta mark | ${mark} tproxy ip to 127.0.0.1:${C.TPROXY_PORT} counter accept\n`;

	if (v6)
		s += `\t\tmeta nfproto ipv6 meta l4proto { tcp, udp } meta mark set meta mark | ${mark} tproxy ip6 to [::1]:${C.TPROXY_PORT} counter accept\n`;

	s += '\t}\n';

	// dnsmasq asks xray for the router's own lookups too, so with FakeDNS the
	// router gets fake addresses as well (curl, package updates): send those
	// connections to xray, which knows the domain behind them.
	if (fake_pool) {
		s += '\n\tchain output {\n';
		s += '\t\ttype route hook output priority mangle; policy accept;\n';
		s += `\t\tip daddr ${fake_pool} meta l4proto { tcp, udp } meta mark set meta mark | ${mark} counter\n`;
		s += '\t}\n';
	}

	if (dns_redirect) {
		s += '\n\tchain dstnat {\n';
		s += '\t\ttype nat hook prerouting priority dstnat; policy accept;\n';
		s += '\t\tiifname @ifaces meta l4proto { tcp, udp } th dport 53 fib daddr type != local counter redirect to :53\n';
		s += '\t}\n';
	}

	return s + '}\n';
}

// dnsmasq lines that put the addresses of a tunnel section's domains into its
// nftables sets. dnsmasq matches a domain together with its subdomains.
function nftset_lines(t) {
	const sets = `4#inet#${C.NFT_TABLE}#tun_${t.name}_d4,6#inet#${C.NFT_TABLE}#tun_${t.name}_d6`;
	let out = '', line = '';

	for (let d in t.domains) {
		if (length(line) + length(d) > 900) {
			out += `nftset=/${line}/${sets}\n`;
			line = '';
		}

		line += (line != '' ? '/' : '') + d;
	}

	if (line != '')
		out += `nftset=/${line}/${sets}\n`;

	return out;
}

// Links are one per line; commas and spaces may appear inside a link.
function link_list(v) {
	const out = [];

	for (let item in type(v) == 'array' ? v : ((v == null || v == '') ? [] : [ v ]))
		for (let l in split(`${item}`, '\n')) {
			l = trim(l);

			if (l != '' && substr(l, 0, 1) != '#')
				push(out, l);
		}

	return out;
}

function name_regexp(src, what, warn) {
	if (src == null || src == '')
		return null;

	try {
		return regexp(src, 'i');
	}
	catch (e) {
		warn(`${what}: invalid regular expression "${src}", ignored`);
		return null;
	}
}

function copy(v) {
	return json(sprintf('%J', v));
}

// Runtime facts about a network interface used by a tunnel section.
function iface_info(model, iface) {
	const r = model.runtime?.ifaces?.[iface];

	return {
		device: r?.device ?? iface,
		up: r ? r.up !== false : true,
		v6: r?.v6 === true
	};
}

// Outbound that sends traffic into a network interface.
function iface_outbound(tag, dev, strategy) {
	return {
		tag: tag,
		protocol: 'freedom',
		settings: {},
		streamSettings: { sockopt: { interface: dev, domainStrategy: strategy } }
	};
}

// All servers of a proxy section: its own links, then nodes of its
// subscriptions that pass the name filters. Returns [{ name, outbound, source }].
function collect_nodes(sec, model, warn) {
	const name = sec['.name'];
	const nodes = [];

	if (sec.proxy_type == 'json') {
		const ob = json_outbound(sec.outbound_json ?? '');
		const why = refused_by_xray(ob);

		if (why)
			warn(`section "${name}": the JSON outbound is ${why}; skipped`);
		else
			push(nodes, { name: 'JSON', outbound: ob, source: 'json' });

		return nodes;
	}

	let n = 0;

	for (let l in link_list(sec.link)) {
		n++;

		try {
			const r = parse_link(l);

			for (let w in r.warnings)
				warn(`section "${name}": ${w}`);

			push(nodes, { name: r.name != '' ? r.name : `${name} ${n}`, outbound: r.outbound, source: 'link' });
		}
		catch (e) {
			warn(`section "${name}": link ${n}: ${e.message}; skipped`);
		}
	}

	// Network interfaces (WireGuard, AmneziaWG, OpenVPN...) as servers of the
	// group: xray sends the traffic straight into the interface.
	for (let iface in entries(sec.iface_node)) {
		const inf = iface_info(model, iface);

		push(nodes, { name: iface, outbound: iface_outbound(null, inf.device, inf.v6 ? null : 'ForceIPv4'), source: 'interface', iface: iface });
	}

	const inc = name_regexp(sec.filter, `section "${name}" filter`, warn);
	const exc = name_regexp(sec.exclude, `section "${name}" exclude`, warn);

	for (let sub in entries(sec.subscription)) {
		const cache = model.subscriptions?.[sub];

		if (!cache) {
			warn(`section "${name}": subscription "${sub}" has not been downloaded yet`);
			continue;
		}

		for (let node in cache.nodes ?? []) {
			const nn = node.name ?? '';

			if ((inc && !match(nn, inc)) || (exc && match(nn, exc)))
				continue;

			try {
				const ob = node.outbound ? copy(node.outbound) : parse_link(node.link).outbound;

				push(nodes, { name: nn, outbound: ob, source: sub });
			}
			catch (e) {
				warn(`section "${name}": server "${nn}" from "${sub}": ${e.message}; skipped`);
			}
		}
	}

	// One such server would keep xray from starting with every other one.
	const usable = [];

	for (let nd in nodes) {
		const why = refused_by_xray(nd.outbound);

		if (why)
			warn(`section "${name}": server "${nd.name}": ${why}; skipped`);
		else
			push(usable, nd);
	}

	// Names identify servers on the dashboard and in saved choices.
	const seen = {};

	for (let nd in usable) {
		const base = nd.name;
		let k = 1;

		while (seen[nd.name])
			nd.name = `${base} (${++k})`;

		seen[nd.name] = true;
	}

	return usable;
}

// Rules of a section from its own entries, geo categories and rule lists.
// G collects what the data updater still has to download.
// Returns { domains, ip4, ip6, geoip (ext: refs for xray), geo4, geo6 (subnets of
// geoip categories for nftables) }.
function collect_rules(sec, model, warn, G) {
	const name = sec['.name'];
	const sources = model.geo?.sources ?? [];
	const domains = uset(), ip4 = uset(), ip6 = uset(), geoip = uset();
	const geo4 = [], geo6 = [], sites = [];

	const geo = (g, text) => {
		const x = resolve(sources, g);

		if (x.error) {
			warn(`section "${name}": ${text}: ${x.error}; skipped`);
			return;
		}

		if (x.state != 'ready') {
			G.pending[x.source] ??= [];
			uniq_push(G.pending[x.source], x.cat);
			warn(`section "${name}": ${text} is not downloaded yet, it starts working after the next geo update`);
			return;
		}

		if (x.count > HEAVY)
			warn(`section "${name}": ${text} has ${x.count} rules, xray may need a lot of memory for it`);

		uniq_push(G.files, x.file);

		if (g.kind == 'geosite') {
			domains.add(`ext:${x.file}:${x.cat}${g.attr}`);
			push(sites, { key: `${x.source}:${x.cat}`, attr: g.attr, text: text });
			return;
		}

		geoip.add(`ext:${x.file}:${g.neg ? '!' : ''}${x.cat}`);

		const c = model.geo?.cidrs?.[`${x.source}:${x.cat}`];

		if (c && !g.neg && !c.reverse) {
			for (let v in c.v4) push(geo4, v);
			for (let v in c.v6) push(geo6, v);
		}
	};

	const add_domain = (d) => {
		const r = norm_domain(d);

		if (r.geo)
			geo(r.geo, d);
		else if (!r.error)
			domains.add(r.value);

		return r.error;
	};

	const add_ip = (i) => {
		const r = norm_ip(i);

		if (r.geo)
			geo(r.geo, i);
		else if (!r.error)
			(r.family == 4 ? ip4 : ip6).add(r.cidr);

		return r.error;
	};

	for (let d in entries(sec.domain)) {
		const e = add_domain(d);

		if (e)
			warn(`section "${name}": ${e}, skipped`);
	}

	for (let i in entries(sec.ip)) {
		const e = add_ip(i);

		if (e)
			warn(`section "${name}": ${e}, skipped`);
	}

	for (let src in [ ...entries(sec.list_url), ...entries(sec.list_file) ]) {
		const text = model.lists?.[src];

		if (text == null) {
			if (match(src, /^https?:\/\//)) {
				uniq_push(G.lists_missing, src);
				warn(`section "${name}": list ${src} is not downloaded yet`);
			}
			else {
				warn(`section "${name}": cannot read list ${src}`);
			}

			continue;
		}

		const L = split_list(text);
		let bad = L.bad;

		for (let d in L.domains)
			if (add_domain(d))
				bad++;

		for (let i in L.ips)
			if (add_ip(i))
				bad++;

		if (bad)
			warn(`section "${name}": list ${src}: skipped ${bad} lines that are not rules`);

		if (length(L.domains) > HEAVY)
			warn(`section "${name}": list ${src} has ${length(L.domains)} domains, xray may need a lot of memory for it`);
	}

	return {
		domains: domains.items, ip4: ip4.items, ip6: ip6.items,
		geoip: geoip.items, geo4: geo4, geo6: geo6, sites: sites
	};
}

// Domains of a kernel-mode tunnel section in the form dnsmasq understands:
// domain: and full: rules and geosite categories (full: matches subdomains as
// well there). keyword: and regexp: only work through xray.
function kernel_domains(name, RL, model, warn) {
	const out = uset();
	let skipped = 0;

	const take = (d) => {
		const m = match(d, /^(domain|full):(.+)$/);

		if (m)
			out.add(m[2]);
		else
			skipped++;
	};

	for (let d in RL.domains)
		if (substr(d, 0, 4) != 'ext:')
			take(d);

	for (let g in RL.sites) {
		const list = model.geo?.domains?.[g.key];

		if (g.attr != '' || list == null) {
			warn(`section "${name}": ${g.text} works through xray only`);
			continue;
		}

		for (let d in list)
			take(d);
	}

	if (skipped)
		warn(`section "${name}": ${skipped} keyword/regexp rules work through xray only`);

	return out.items;
}


// Tag of a server: section and a hash of its outbound. It stays the same while
// the server does, whatever the order or the names in the subscription, so a
// new server list can be applied to running xray server by server.
function node_tag(section, ob, used) {
	const body = { ...ob };

	delete body.tag;

	const base = `n-${section}-${substr(list_key(sprintf('%J', body)), 0, 8)}`;
	let tag = base, k = 1;

	while (used[tag])
		tag = `${base}-${++k}`;

	used[tag] = true;

	return tag;
}

// Second-level public suffixes under country domains: example.co.uk, site.com.ru.
const SLD = [ 'ac', 'co', 'com', 'edu', 'gov', 'net', 'org', 'or', 'ne', 'go', 'mil', 'nom', 'ltd', 'plc', 'msk', 'spb' ];

// The registered domain of a server host: provider.com for nl1.provider.com.
function base_domain(host) {
	const l = split(host, '.');
	const n = length(l);

	if (n <= 2)
		return host;

	const take = (length(l[n - 1]) == 2 && index(SLD, l[n - 2]) >= 0) ? 3 : 2;

	return join('.', slice(l, n - take));
}

function memlimit_mib(S, R) {
	const v = int_opt(S.memlimit, 0, 16, 4096);

	if (v)
		return v;

	const total = int_opt(R.mem_total_kb, 262144, 1, 0x7fffffff);

	const auto = int(total / 1024 / 4);

	return auto < 32 ? 32 : auto;
}

export function build(model) {
	const S = model.settings ?? {};
	const D = model.dns ?? {};
	const R = model.runtime ?? {};
	const st = { warnings: [], errors: [], sections: [] };
	const warn = (m) => push(st.warnings, m);
	const fail = (m) => push(st.errors, m);

	const mode = S.mode == 'global' ? 'global' : 'lists';
	const family_key = exists(FAMILY, S.ip_family) ? S.ip_family : 'prefer_ipv4';
	const F = FAMILY[family_key];
	const v6 = R.ipv6 !== false && family_key != 'ipv4_only';
	const fakedns = is_true(D.fakedns);
	const log_level = index(LOG_LEVELS, S.log_level) >= 0 ? S.log_level : 'warning';

	// The first outbound takes traffic that no rule names and traffic routed
	// to a tag that does not exist (a server being replaced): it is dropped,
	// never sent direct by mistake.
	const outbounds = [
		{ tag: 'block', protocol: 'blackhole', settings: {} },
		{ tag: 'direct', protocol: 'freedom', settings: {}, streamSettings: { sockopt: { domainStrategy: F.freedom } } }
	];

	const sets = { block4: uset(), block6: uset(), direct4: uset(), direct6: uset() };
	const geo_pending = {};
	const geo_files = [];
	const lists_missing = [];

	const proxy_domains = uset();
	const excl_domains = uset();
	const tun_domains4 = uset();		// tunnel sections without IPv6: no AAAA answers
	const tun_domains = uset();
	const tunnels = [];			// kernel-mode tunnel sections
	const tun_all = [];			// every tunnel section, for the watchdog
	const tun_rules = [];
	let tun_index = 0;

	// Local SOCKS/HTTP ports that lead into a section.
	const local_inbounds = [];
	const local_rules = [];
	const local_ports = {};
	const RESERVED_PORTS = [ C.TPROXY_PORT, C.DNS_PORT, C.API_PORT, C.METRICS_PORT, C.HELPER_PORT ];

	const add_local = (sec, target) => {
		const sn = sec['.name'];

		if (sec.local_port == null || sec.local_port == '')
			return;

		const port = int_opt(sec.local_port, 0, 1024, 65535);

		if (!port || index(RESERVED_PORTS, port) >= 0) {
			warn(`section "${sn}": local port ${sec.local_port} cannot be used (1024-65535, not Mayhem's own ports)`);
			return;
		}

		if (local_ports[port]) {
			warn(`section "${sn}": local port ${port} is already used by section "${local_ports[port]}"`);
			return;
		}

		local_ports[port] = sn;

		const ib = {
			tag: `local-${sn}`,
			listen: v6 ? '::' : '0.0.0.0',
			port: port,
			protocol: 'mixed',
			settings: { auth: 'noauth', udp: true },
			sniffing: { enabled: true, destOverride: [ 'http', 'tls', 'quic' ], routeOnly: true }
		};

		if (sec.local_user && sec.local_pass) {
			ib.settings.auth = 'password';
			ib.settings.accounts = [ { user: sec.local_user, pass: sec.local_pass } ];
		}

		push(local_inbounds, ib);
		push(local_rules, { inboundTag: [ ib.tag ], ...target });
	};
	const server_hosts = [];		// DoH hosts
	const node_hosts = [];			// server hosts (or their domains)
	const block_rules = [];
	const section_rules = [];
	const proxy_targets = {};
	const iface_targets = {};		// tunnel sections: the rest of the traffic may go there
	const node_tags = [];
	const balancers = [];
	const overrides = [];
	const observe = [];
	const state = { sections: {} };
	let first_proxy = null;

	// --- sections -----------------------------------------------------------

	for (let sec in model.sections ?? []) {
		const name = sec['.name'];
		const info = { name: name, type: sec.type ?? 'proxy', enabled: is_true(sec.enabled ?? '1'), ok: false };

		push(st.sections, info);

		if (!info.enabled)
			continue;

		if (!match(name ?? '', /^[A-Za-z0-9_]+$/)) {
			info.error = 'invalid section name';
			warn(`section "${name}": invalid name, skipped`);
			continue;
		}

		const RL = collect_rules(sec, model, warn, { pending: geo_pending, files: geo_files, lists_missing: lists_missing });
		const domains = RL.domains, ips4 = RL.ip4, ips6 = RL.ip6;

		let target;

		switch (info.type) {
		case 'proxy':
			// No servers of its own: the active server of the server list.
			if (sec.use_pool) {
				target = proxy_targets.pool;

				if (!target) {
					info.error = 'the server list has no servers';
					warn(`section "${name}": the server list has no working servers, section skipped`);
					continue;
				}

				state.sections[name] = { type: 'proxy', pool: true };
				proxy_targets[name] = target;
				add_local(sec, target);
				proxy_domains.add_all(domains);
				break;
			}

			let nodes;

			try {
				nodes = collect_nodes(sec, model, warn);
			}
			catch (e) {
				info.error = e.message;
				warn(`section "${name}": ${e.message}; section skipped`);
				continue;
			}

			if (!length(nodes)) {
				info.error = 'no servers';
				warn(sec.pool ? 'the server list is empty: add a server or a subscription'
					: `section "${name}": no servers (links or subscription nodes), skipped`);
				continue;
			}

			if (length(nodes) > C.MAX_NODES) {
				warn(`section "${name}": ${length(nodes)} servers, only the first ${C.MAX_NODES} are used`);
				nodes = slice(nodes, 0, C.MAX_NODES);
			}

			const smode = sec.select == 'manual' ? 'manual' : 'auto';
			const sinfo = { type: 'proxy', mode: length(nodes) > 1 ? smode : 'single', nodes: [] };
			const used = {};

			for (let i = 0; i < length(nodes); i++) {
				const ob = nodes[i].outbound;
				const host = outbound_host(ob);

				apply_sockopt(ob, F.sockopt);
				apply_mux(ob, S);
				ob.tag = node_tag(name, ob, used);
				push(outbounds, ob);
				push(node_tags, ob.tag);

				// In "everything through proxy" mode a new server of the same
				// provider must resolve the same way without a restart: the
				// whole domain of the provider goes to the domestic DNS.
				if (host && !is_ip(host))
					uniq_push(node_hosts, mode == 'global' ? `domain:${base_domain(host)}` : `full:${host}`);

				push(sinfo.nodes, {
					tag: ob.tag,
					name: nodes[i].name,
					protocol: nodes[i].iface ? 'interface' : ob.protocol,
					address: host,
					port: outbound_port(ob),
					udp: outbound_udp(ob),
					source: nodes[i].source,
					iface: nodes[i].iface
				});
			}

			// Even one server goes through a balancer: the routing does not
			// name servers, so they can change in running xray.
			if (length(nodes) == 1) {
				push(balancers, { tag: `bal-${name}`, selector: [ `n-${name}-` ], strategy: { type: 'random' } });
				target = { balancerTag: `bal-${name}` };
				info.node = sinfo.nodes[0].name;
			}
			else {
				const bal = `bal-${name}`;
				const byname = (n) => filter(sinfo.nodes, (x) => x.name == n)[0];
				let pick = null;

				if (smode == 'manual') {
					pick = byname(sec.selected);

					if (sec.selected && !pick)
						warn(`section "${name}": selected server "${sec.selected}" is gone, using the first one`);

					pick ??= sinfo.nodes[0];
					sinfo.selected = pick.tag;
				}
				else if (sec.override) {
					pick = byname(sec.override);

					if (pick)
						sinfo.override = pick.tag;
					else
						warn(`section "${name}": pinned server "${sec.override}" is gone, back to automatic choice`);
				}

				// A fallback tag makes xray require the observatory, which only
				// watches automatic sections. A manual section gets its server
				// through the override that is applied before traffic is let in.
				const balancer = {
					tag: bal,
					selector: [ `n-${name}-` ],
					strategy: { type: smode == 'auto' ? 'leastPing' : 'random' }
				};

				// The fallback (no server checked yet, or none answers) is a
				// copy of the pinned or first server under a tag of its own:
				// the balancer stays the same when the servers change.
				if (smode == 'auto') {
					const src = filter(outbounds, (o) => o.tag == (pick ?? sinfo.nodes[0]).tag)[0];

					push(outbounds, { ...copy(src), tag: `f-${name}` });
					balancer.fallbackTag = `f-${name}`;
				}

				push(balancers, balancer);

				if (pick)
					push(overrides, `${bal} ${pick.tag}`);

				if (smode == 'auto')
					push(observe, `n-${name}-`);

				sinfo.balancer = bal;
				target = { balancerTag: bal };
				info.node = `${length(nodes)} servers`;
			}

			state.sections[name] = sinfo;
			proxy_targets[name] = target;
			first_proxy ??= name;
			add_local(sec, target);

			proxy_domains.add_all(domains);
			break;

		case 'exclusion':
			target = { outboundTag: 'direct' };
			state.sections[name] = { type: 'exclusion' };

			excl_domains.add_all(domains);

			sets.direct4.add_all(ips4);
			sets.direct4.add_all(RL.geo4);
			sets.direct6.add_all(ips6);
			sets.direct6.add_all(RL.geo6);
			break;

		case 'block':
			target = { outboundTag: 'block' };
			state.sections[name] = { type: 'block' };

			sets.block4.add_all(ips4);
			sets.block4.add_all(RL.geo4);
			sets.block6.add_all(ips6);
			sets.block6.add_all(RL.geo6);
			break;

		case 'interface':
			const iface = sec.interface;

			if (!match(iface ?? '', /^[A-Za-z0-9_.-]+$/)) {
				info.error = 'no interface';
				warn(`section "${name}": no network interface chosen, skipped`);
				continue;
			}

			const inf = iface_info(model, iface);
			const kernel = (sec.route_mode ?? 'kernel') != 'xray';
			const tag = `i-${name}-0`;
			const bal = `bal-${name}`;
			const tv6 = v6 && inf.v6;

			// The balancer has one member; the tunnel watchdog points it at
			// "direct" while the tunnel is down.
			push(outbounds, iface_outbound(tag, inf.device, tv6 ? F.sockopt : 'ForceIPv4'));
			push(balancers, { tag: bal, selector: [ `i-${name}-` ], strategy: { type: 'random' } });
			target = { balancerTag: bal };
			iface_targets[name] = target;

			const tinfo = {
				type: 'interface', mode: kernel ? 'kernel' : 'xray', interface: iface, device: inf.device,
				balancer: bal, v6: tv6, nodes: [ { tag: tag, name: iface, protocol: 'interface' } ]
			};

			if (!inf.up)
				warn(`section "${name}": interface ${iface} is down, its traffic goes direct until it is up`);

			const tline = { name: name, device: inf.device, mark: '-', table: '-', v6: tv6 };

			push(tun_all, tline);

			(tv6 ? tun_domains : tun_domains4).add_all(domains);

			if (kernel) {
				if (++tun_index > C.TUN_MAX) {
					info.error = 'too many tunnel sections';
					warn(`section "${name}": at most ${C.TUN_MAX} tunnel sections can work in kernel mode, skipped`);
					continue;
				}

				const t = {
					name: name, index: tun_index, device: inf.device, v6: tv6,
					ip4: [ ...ips4, ...RL.geo4 ], ip6: tv6 ? [ ...ips6, ...RL.geo6 ] : [],
					domains: kernel_domains(name, RL, model, warn)
				};

				push(tunnels, t);
				tinfo.mark = tline.mark = tun_mark(t.index);
				tinfo.table = tline.table = C.TUN_TABLE + t.index;

				// Kernel sections come first: same order in xray, which
				// catches what the DNS path missed (by SNI).
				if (length(domains))
					push(tun_rules, { domain: domains, ...target });

				const tips = [ ...ips4, ...ips6, ...RL.geoip ];

				if (length(tips))
					push(tun_rules, { ip: tips, ...target });

				state.sections[name] = tinfo;
				info.node = `${iface} (kernel)`;
				info.ok = true;
				add_local(sec, target);
				continue;
			}

			state.sections[name] = tinfo;
			info.node = `${iface} (xray)`;
			add_local(sec, target);
			break;

		default:
			info.error = `unknown type "${info.type}"`;
			warn(`section "${name}": unknown type "${info.type}", skipped`);
			continue;
		}

		const list = info.type == 'block' ? block_rules : section_rules;

		if (length(domains))
			push(list, { domain: domains, ...target });

		const ips = [ ...ips4, ...ips6, ...RL.geoip ];

		if (length(ips))
			push(list, { ip: ips, ...target });

		info.ok = true;
	}

	// --- default route ------------------------------------------------------

	// The default section: the rest of the traffic in "everything through
	// proxy" mode, remote DNS and downloads go through its active server.
	const want = S.default_section;
	const first_iface = keys(iface_targets)[0];
	let default_name = null;

	if (want && (proxy_targets[want] || iface_targets[want]))
		default_name = want;
	else {
		default_name = first_proxy ?? first_iface;

		if (want && default_name)
			warn(`default section "${want}" does not work, using "${default_name}"`);
	}

	const default_target = default_name ? (proxy_targets[default_name] ?? iface_targets[default_name]) : null;
	let final_target = { outboundTag: 'direct' };

	if (mode == 'global') {
		if (default_target)
			final_target = default_target;
		else
			fail('the rest of the traffic needs a server: add one or a subscription on the Server list page, or turn "The rest of the traffic through the tunnel" off');
	}

	// --- DNS ----------------------------------------------------------------

	const domestic = [];
	const remote = [];

	// The router's own address would send the queries back to dnsmasq and
	// xray: it stands for the servers the router got from the provider.
	const own = [ '127.0.0.1', '::1', 'localhost', ...(R.router_ips ?? []) ];

	for (let s in entries(D.domestic)) {
		const r = dns_server(s);

		if (r.error)
			warn(`domestic DNS: ${r.error}`);
		else if (index(own, r.host) < 0)
			push(domestic, r);
	}

	if (!length(domestic)) {
		for (let ip in R.wan_dns ?? [])
			if (is_ip(ip) && !match(ip, /^(127\.|::1$)/))
				push(domestic, { address: ip, host: ip });

		if (!length(domestic)) {
			warn('no DNS servers received from the provider, using the public fallback');

			for (let ip in C.FALLBACK_DOMESTIC_DNS)
				push(domestic, { address: ip, host: ip });
		}
	}

	for (let s in length(entries(D.remote)) ? entries(D.remote) : C.DEFAULT_REMOTE_DNS) {
		const r = dns_server(s);

		if (r.error)
			warn(`remote DNS: ${r.error}`);
		else
			push(remote, r);
	}

	if (!length(remote))
		for (let s in C.DEFAULT_REMOTE_DNS)
			push(remote, dns_server(s));

	// DoH hostnames must be resolved without the DoH server itself.
	for (let r in [ ...remote, ...domestic ])
		if (!is_ip(r.host))
			uniq_push(server_hosts, `full:${r.host}`);

	const ns = (srv, extra) => {
		const o = { address: srv.address };

		if (srv.port)
			o.port = srv.port;

		for (let k in extra)
			o[k] = extra[k];

		return o;
	};

	const servers = [];
	const host_rules = [ ...server_hosts, ...node_hosts ];

	if (length(host_rules))
		for (let d in domestic)
			push(servers, ns(d, { domains: host_rules, skipFallback: true }));

	if (mode == 'lists') {
		if (length(proxy_domains.items)) {
			if (fakedns)
				push(servers, { address: 'fakedns', domains: proxy_domains.items, skipFallback: true });

			for (let r in remote)
				push(servers, ns(r, { domains: proxy_domains.items, skipFallback: true }));
		}

		// Tunnel sections: real addresses (dnsmasq puts them into the
		// kernel sets), no IPv6 answers when the tunnel has no IPv6.
		if (length(tun_domains4.items))
			for (let r in remote)
				push(servers, ns(r, { domains: tun_domains4.items, skipFallback: true, queryStrategy: 'UseIPv4' }));

		if (length(tun_domains.items))
			for (let r in remote)
				push(servers, ns(r, { domains: tun_domains.items, skipFallback: true }));

		for (let d in domestic)
			push(servers, ns(d));
	}
	else {
		if (length(excl_domains.items))
			for (let d in domestic)
				push(servers, ns(d, { domains: excl_domains.items, skipFallback: true }));

		if (length(tun_domains4.items))
			for (let r in remote)
				push(servers, ns(r, { domains: tun_domains4.items, skipFallback: true, queryStrategy: 'UseIPv4' }));

		if (fakedns)
			push(servers, { address: 'fakedns' });

		for (let r in remote)
			push(servers, ns(r));
	}

	// Address for non-A/AAAA queries that the DNS outbound passes through.
	const plain = filter(domestic, (d) => is_ip(d.address))[0] ??
		{ address: C.FALLBACK_DOMESTIC_DNS[0] };

	push(outbounds, {
		tag: 'dns-out',
		protocol: 'dns',
		settings: {
			address: plain.address,
			port: plain.port ?? 53,
			userLevel: DNS_LEVEL,
			rules: [
				{ action: 'hijack', qType: '1,28' },
				{ action: 'return', qType: '65', rCode: 0 },
				{ action: 'direct' }
			]
		}
	});

	// --- routing ------------------------------------------------------------

	// Local SOCKS helper: user "<node tag>" goes through that server, user
	// "sec-<section>" through the section. Used for URL tests and for
	// downloading subscriptions through a section.
	const helper_accounts = [];
	const rules = [];

	for (let sn in [ ...keys(proxy_targets), ...keys(iface_targets) ]) {
		push(helper_accounts, { user: `sec-${sn}`, pass: C.HELPER_PASS });
		push(rules, { inboundTag: [ 'helper-in' ], user: [ `sec-${sn}` ], ...(proxy_targets[sn] ?? iface_targets[sn]) });
	}

	// Users of single servers come last, each rule with a tag: when the servers
	// change, these rules are replaced in running xray.
	const helper_rules = [];

	for (let t in node_tags) {
		push(helper_accounts, { user: t, pass: C.HELPER_PASS });
		push(helper_rules, { ruleTag: `h-${t}`, inboundTag: [ 'helper-in' ], user: [ t ], outboundTag: t });
	}

	push(rules, { inboundTag: [ 'dns-in' ], outboundTag: 'dns-out' });

	if (is_true(D.hijack ?? '1'))
		push(rules, { inboundTag: [ 'tproxy-in' ], port: '53', outboundTag: 'dns-out' });

	// Remote DNS goes through the active server of the main section unless
	// turned off; otherwise, or with no working section, it goes direct
	// (encrypted when it is DoH).
	if (default_target && is_true(D.via_proxy ?? '1')) {
		const ips = [], doms = [];

		for (let r in remote)
			if (is_ip(r.host))
				uniq_push(ips, r.host);
			else
				uniq_push(doms, `full:${r.host}`);

		if (length(ips))
			push(rules, { inboundTag: [ 'dns-module' ], ip: ips, ...default_target });

		if (length(doms))
			push(rules, { inboundTag: [ 'dns-module' ], domain: doms, ...default_target });
	}

	push(rules, { inboundTag: [ 'dns-module' ], outboundTag: 'direct' });

	for (let r in local_rules)
		push(rules, r);

	// Section rules are for intercepted traffic only, so that helper users
	// reach their own rules at the end.
	const intercepted = (r) => ({ inboundTag: [ 'tproxy-in' ], ...r });

	// Without QUIC browsers fall back to TCP, which proxies carry better.
	if (is_true(S.block_quic))
		push(rules, intercepted({ network: 'udp', port: '443', outboundTag: 'block' }));

	for (let r in block_rules)
		push(rules, intercepted(r));

	// BitTorrent is recognized by sniffing its first packets.
	if (is_true(S.torrent_direct))
		push(rules, intercepted({ protocol: [ 'bittorrent' ], outboundTag: 'direct' }));

	for (let r in tun_rules)
		push(rules, intercepted(r));

	for (let r in section_rules)
		push(rules, intercepted(r));

	push(rules, intercepted({ network: 'tcp,udp', ...final_target }));

	for (let r in helper_rules)
		push(rules, r);

	// --- assemble -----------------------------------------------------------

	const sniff = [ 'http', 'tls', 'quic' ];

	if (fakedns)
		unshift(sniff, 'fakedns');

	// FakeDNS in global mode gives every domain a fake address, so xray only
	// knows the domain and IP rules (geoip:ru in an exclusion, say) never
	// match: let xray resolve the domain when it reaches such a rule. The
	// lookup skips FakeDNS and is cached by xray's DNS. In lists mode only
	// listed domains get fake addresses, and their domain rules match first.
	const ip_strategy = (fakedns && mode == 'global' && length(filter(rules, (r) => r.ip))) ? 'IPOnDemand' : 'AsIs';

	const xray = {
		log: {
			loglevel: log_level,
			access: log_level == 'debug' ? '' : 'none',
			dnsLog: log_level == 'debug'
		},
		dns: {
			tag: 'dns-module',
			queryStrategy: F.dns,
			disableFallbackIfMatch: true,
			servers: servers
		},
		inbounds: [
			{
				tag: 'tproxy-in',
				listen: v6 ? '::' : '0.0.0.0',
				port: C.TPROXY_PORT,
				protocol: 'dokodemo-door',
				settings: { network: 'tcp,udp', followRedirect: true },
				streamSettings: { sockopt: { tproxy: 'tproxy' } },
				sniffing: { enabled: true, destOverride: sniff, routeOnly: true }
			},
			{
				tag: 'dns-in',
				listen: '127.0.0.1',
				port: C.DNS_PORT,
				protocol: 'dokodemo-door',
				settings: { address: plain.address, port: 53, network: 'tcp,udp', userLevel: DNS_LEVEL }
			}
		],
		outbounds: outbounds,
		routing: { domainStrategy: ip_strategy, rules: rules, balancers: balancers },
		api: { tag: 'api', listen: `127.0.0.1:${C.API_PORT}`, services: [ 'RoutingService', 'HandlerService' ] },
		metrics: { tag: 'metrics', listen: `127.0.0.1:${C.METRICS_PORT}` },
		stats: {},
		policy: {
			levels: { '1': { connIdle: DNS_IDLE } },	// '1' is DNS_LEVEL
			system: { statsOutboundUplink: true, statsOutboundDownlink: true }
		}
	};

	if (length(helper_accounts))
		push(xray.inbounds, {
			tag: 'helper-in',
			listen: '127.0.0.1',
			port: C.HELPER_PORT,
			protocol: 'socks',
			settings: { auth: 'password', accounts: helper_accounts, udp: false }
		});

	for (let ib in local_inbounds)
		push(xray.inbounds, ib);

	if (length(observe)) {
		const iv = match(S.probe_interval ?? '', /^[0-9]+[smh]$/) ? S.probe_interval : C.DEFAULT_PROBE_INTERVAL;
		const url = match(S.probe_url ?? '', /^https?:\/\//) ? S.probe_url : C.DEFAULT_PROBE_URL;

		xray.observatory = { subjectSelector: observe, probeURL: url, probeInterval: iv, enableConcurrency: true };
	}

	if (fakedns)
		xray.fakedns = [ { ipPool: C.FAKEDNS_POOL, poolSize: C.FAKEDNS_POOL_SIZE } ];

	// Without nftset support in dnsmasq, kernel sections only get the
	// subnets from their rules; domains go through xray.
	const nftset = length(tunnels) && R.dnsmasq_nftset !== false;
	const dns_redirect = nftset && is_true(D.hijack ?? '1');

	if (length(tunnels) && !nftset)
		warn('kernel mode needs dnsmasq-full (nftset support): domains of tunnel sections go through xray until it is installed');

	// What running xray cannot change: everything but the servers. procd
	// restarts xray when this changes; otherwise live.uc swaps the servers in
	// place. With "only matched lists" a new server host needs nothing from
	// DNS: names outside the lists go to the domestic DNS anyway.
	const key = copy(xray);

	key.outbounds = filter(key.outbounds, (o) => !match(o.tag, /^[nf]-/));
	key.routing.rules = filter(key.routing.rules, (r) => !match(r.ruleTag ?? '', /^h-/));

	for (let ib in key.inbounds)
		if (ib.tag == 'helper-in')
			ib.settings.accounts = filter(ib.settings.accounts, (a) => !match(a.user, /^n-/));

	if (mode == 'lists' && length(host_rules))
		for (let i = 0; i < length(domestic); i++)
			key.dns.servers[i].domains = server_hosts;

	state.default_section = default_name;
	state.geo_pending = geo_pending;
	state.lists_missing = lists_missing;
	state.generated = R.now ?? time();
	state.mode = mode;
	state.probe_url = xray.observatory?.probeURL ?? (match(S.probe_url ?? '', /^https?:\/\//) ? S.probe_url : C.DEFAULT_PROBE_URL);

	return {
		ok: !length(st.errors),
		mode: mode,
		xray: xray,
		nft: build_nft(S, v6, {
			ifaces: entries(S.interface),
			block4: sets.block4.items, block6: sets.block6.items,
			direct4: sets.direct4.items, direct6: sets.direct6.items
		}, tunnels, dns_redirect, fakedns ? C.FAKEDNS_POOL : null),
		dnsmasq: `server=127.0.0.1#${C.DNS_PORT}\nno-resolv\n` +
			(nftset ? join('', map(tunnels, (t) => nftset_lines(t))) : ''),
		// "section device mark table v6" per tunnel section; mark and table are
		// "-" in xray mode.
		tunnels: join('', map(tun_all, (t) => `${t.name} ${t.device} ${t.mark} ${t.table} ${t.v6 ? 1 : 0}\n`)),
		key: key,
		memlimit_mib: memlimit_mib(S, R),
		ipv6: v6,
		state: state,
		overrides: overrides,
		geo_files: geo_files,
		status: st
	};
};
