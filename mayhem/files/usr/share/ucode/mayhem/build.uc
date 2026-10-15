// Mayhem: builds the Xray config, the nftables ruleset and the dnsmasq snippet
// from a configuration model. Pure function: no file or system access, so it
// can be tested off-device. See model.uc for how the model is read from UCI.

'use strict';

import { parse_link, outbound_host, outbound_port, outbound_udp, refused_by_xray } from 'mayhem.links';
import { is_true, entries, norm_domain, norm_ip, is_ip, dns_server, split_list, list_key } from 'mayhem.rules';
import { resolve, HEAVY, KERNEL_DOMAINS_MAX } from 'mayhem.geo';
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
// DNS sessions get their own level with a short idle timeout. xray itself
// gives up on a DNS server after 4 s, so a session that lives 4-8 s after the
// query (xray checks once per timeout) loses no answer that could come: at 30
// queries a second it holds 22 MB instead of 28 with 10 s.
const DNS_LEVEL = 1;
const DNS_IDLE = 4;

// Every UDP flow that reaches xray is a session (2 sockets, 3 goroutines,
// ~35 KB), and in "lists" mode that is every flow of the network: a torrent
// client's DHT alone opens thousands, each living 2-3 minutes after its last
// packet. UDP that goes direct leaves through an outbound of its own whose
// sessions close 45-90 s after their last packet (xray checks for activity
// once per connIdle); TCP keeps the default 300 s, idle push connections must
// live. UDP that is alive sends more often: NAT mappings on home routers
// expire after 30-60 s, so apps keep them warm.
const UDP_LEVEL = 2;
const UDP_IDLE = 45;

// Rules taken from one downloaded or local list (see collect_rules).
const LIST_RULES_MAX = 200000;

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

// Sets that keep single addresses apart (name -> true), see nft_set().
let HOSTSETS = {};

function nft_elems(elems) {
	let s = '\t\telements = {';

	// geoip sets have thousands of subnets: a few per line keeps lines short.
	for (let i = 0; i < length(elems); i += 8)
		s += `${i ? ',' : ''}\n\t\t\t${join(', ', slice(elems, i, i + 8))}`;

	return s + '\n\t\t}\n';
}

// An address set. In an interval set every element is a node of a tree:
// geoip:ru-blocked (75 000 single addresses of 88 000) took 12.5 MB of kernel
// memory. Single addresses, when there are many, go into a hash set of their
// own (<name>_h, 8.7 MB for the same), and every rule that names the set is
// repeated for it (build_nft).
const HOSTSET_MIN = 256;

function nft_set(name, ftype, elems) {
	const v6 = ftype == 'ipv6_addr';
	const hosts = [], seen = {};
	let nets = [];

	for (let e in elems) {
		const m = match(e, v6 ? /^([0-9A-Fa-f:.]+)(\/128)?$/ : /^([0-9.]+)(\/32)?$/);

		if (m) {
			if (!seen[m[1]]) {
				seen[m[1]] = true;
				push(hosts, m[1]);
			}
		}
		else
			push(nets, e);
	}

	let s = '';

	if (length(hosts) >= HOSTSET_MIN) {
		HOSTSETS[name] = true;
		s += `\tset ${name}_h {\n\t\ttype ${ftype}\n${nft_elems(hosts)}\t}\n`;
	}
	else
		nets = elems;

	s += `\tset ${name} {\n\t\ttype ${ftype}\n\t\tflags interval\n\t\tauto-merge\n`;

	if (length(nets))
		s += nft_elems(nets);

	return s + '\t}\n';
}

// Every rule line that names a set with a hash part comes twice: once for
// the subnets, once for the single addresses.
function with_hostsets(text) {
	if (!length(keys(HOSTSETS)))
		return text;

	let out = '';

	for (let line in split(text, '\n')) {
		const m = match(line, /^\t\t.*[ ]@([A-Za-z0-9_]+)( |$)/);

		if (m && HOSTSETS[m[1]])
			out += replace(line, `@${m[1]}`, `@${m[1]}_h`) + '\n';

		out += line + '\n';
	}

	return substr(out, 0, length(out) - 1);
}

// Marks for tunnel sections in kernel mode: TUN_MARK | index, matched with
// TUN_MASK, so other users of the mark (fw4, mwan3) keep their bits.
function tun_mark(idx) {
	return sprintf('0x%x', C.TUN_MARK | idx);
}

// cap: null when every flow of the LAN goes to xray (global mode, or
// "capture all"); otherwise { px4, px6 }: only what the rules send through a
// proxy reaches xray - fake addresses of its domains and the subnets of its
// IP rules - and the rest of the traffic never leaves the kernel.
function build_nft_text(S, v6, sets, tunnels, dns_redirect, fake_pool, kdef, cap) {
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
	s += nft_set('bypass4', 'ipv4_addr', sets.bypass4 ?? []);
	s += nft_set('bypass6', 'ipv6_addr', sets.bypass6 ?? []);
	s += `\tset bypass_mac {\n\t\ttype ether_addr\n${length(sets.bypass_mac ?? []) ? `\t\telements = { ${join(', ', sets.bypass_mac)} }\n` : ''}\t}\n`;

	// Tunnel sections in kernel mode: subnets from the rules, plus addresses
	// that dnsmasq adds while it resolves the section's domains.
	for (let t in tunnels) {
		s += nft_set(`tun_${t.name}_4`, 'ipv4_addr', t.ip4);
		s += nft_set(`tun_${t.name}_6`, 'ipv6_addr', t.ip6);
		s += `\tset tun_${t.name}_d4 {\n\t\ttype ipv4_addr\n\t}\n`;
		s += `\tset tun_${t.name}_d6 {\n\t\ttype ipv6_addr\n\t}\n`;
	}

	if (cap) {
		s += nft_set('px4', 'ipv4_addr', cap.px4);
		s += nft_set('px6', 'ipv6_addr', cap.px6);
	}

	// The rest of the traffic into a kernel tunnel: what still has to reach
	// xray (proxy sections) or stay out of the tunnel (exclusions, blocking)
	// is told by subnets and by addresses dnsmasq adds for their domains.
	if (kdef) {
		s += nft_set('px_4', 'ipv4_addr', kdef.px4);
		s += nft_set('px_6', 'ipv6_addr', kdef.px6);

		for (let n in [ 'px_d', 'dir_d', 'blk_d' ]) {
			s += `\tset ${n}4 {\n\t\ttype ipv4_addr\n\t}\n`;
			s += `\tset ${n}6 {\n\t\ttype ipv6_addr\n\t}\n`;
		}
	}

	s += '\n\tchain prerouting {\n';
	s += '\t\ttype filter hook prerouting priority mangle; policy accept;\n';

	// The router's own connections to FakeDNS addresses (chain output) come
	// back through lo with the mark.
	if (fake_pool)
		s += `\t\tiifname "lo" meta mark & ${mark} == ${mark} ip daddr ${fake_pool} meta l4proto { tcp, udp } tproxy ip to 127.0.0.1:${C.TPROXY_PORT} counter accept\n`;

	s += '\t\tiifname != @ifaces return\n';

	// Devices left alone (settings.bypass): nothing of theirs is touched,
	// only fake addresses still reach xray - the router's DNS gives them out
	// for proxied domains, and they lead nowhere else.
	const fake_only = fake_pool
		? `meta l4proto { tcp, udp } meta mark set meta mark | ${mark} tproxy ip to 127.0.0.1:${C.TPROXY_PORT} counter accept`
		: null;

	for (let m in [ 'ether saddr @bypass_mac', 'ip saddr @bypass4', 'ip6 saddr @bypass6' ]) {
		if (fake_only && m != 'ip6 saddr @bypass6')
			s += `\t\t${m} ip daddr ${fake_pool} ${fake_only}\n`;

		s += `\t\t${m} return\n`;
	}

	s += '\t\tfib daddr type { local, broadcast, multicast } return\n';
	s += '\t\tip daddr @local4 return\n';
	s += '\t\tip6 daddr @local6 return\n';
	s += '\t\tip daddr @block4 counter drop\n';
	s += '\t\tip6 daddr @block6 counter drop\n';

	if (kdef) {
		s += '\t\tip daddr @blk_d4 counter drop\n';
		s += '\t\tip6 daddr @blk_d6 counter drop\n';
	}

	// Kernel tunnels go before everything else: the mark selects their
	// routing table, and the packet never reaches xray.
	for (let t in tunnels) {
		const m = `meta mark set meta mark & ${keep} | ${tun_mark(t.index)}`;

		s += `\t\tip daddr @tun_${t.name}_4 ${m} counter return\n`;
		s += `\t\tip daddr @tun_${t.name}_d4 ${m} counter return\n`;
		s += `\t\tip6 daddr @tun_${t.name}_6 ${m} counter return\n`;
		s += `\t\tip6 daddr @tun_${t.name}_d6 ${m} counter return\n`;
	}

	if (kdef) {
		const m = `meta mark set meta mark & ${keep} | ${kdef.mark}`;
		const tp4 = `meta l4proto { tcp, udp } meta mark set meta mark | ${mark} tproxy ip to 127.0.0.1:${C.TPROXY_PORT} counter accept`;
		const tp6 = `meta nfproto ipv6 meta l4proto { tcp, udp } meta mark set meta mark | ${mark} tproxy ip6 to [::1]:${C.TPROXY_PORT} counter accept`;

		s += '\t\tip daddr @direct4 counter return\n';
		s += '\t\tip6 daddr @direct6 counter return\n';
		s += '\t\tip daddr @dir_d4 counter return\n';
		s += '\t\tip6 daddr @dir_d6 counter return\n';

		if (fake_pool)
			s += `\t\tip daddr ${fake_pool} ${tp4}\n`;

		s += `\t\tip daddr @px_4 ${tp4}\n`;
		s += `\t\tip daddr @px_d4 ${tp4}\n`;

		if (v6) {
			s += `\t\tip6 daddr @px_6 ${tp6}\n`;
			s += `\t\tip6 daddr @px_d6 ${tp6}\n`;
		}

		// DNS goes to dnsmasq (chain dstnat), which fills the sets.
		if (dns_redirect)
			s += '\t\tmeta l4proto { tcp, udp } th dport 53 return\n';

		// QUIC off, as xray does it for the traffic it gets: browsers fall
		// back to TCP. (Reject is not allowed in prerouting.)
		if (kdef.no_quic)
			s += '\t\tmeta l4proto udp th dport 443 counter drop\n';

		// Torrents direct: only xray tells BitTorrent apart, so the kernel
		// takes web traffic (TCP 80/443, QUIC) and the rest goes through
		// xray, which sends torrents direct and the others into the tunnel.
		const sel = kdef.torrent
			? [ 'meta l4proto tcp th dport { 80, 443 } ', 'meta l4proto udp th dport 443 ', 'meta l4proto != { tcp, udp } ' ]
			: [ '' ];

		for (let x in sel) {
			s += `\t\tmeta nfproto ipv4 ${x}${m} counter return\n`;

			// A tunnel without IPv6: IPv6 goes on through xray as before.
			if (kdef.v6)
				s += `\t\tmeta nfproto ipv6 ${x}${m} counter return\n`;
		}
	}

	s += '\t\tmeta l4proto != { tcp, udp } return\n';

	// DNS goes to dnsmasq (chain dstnat): its answers carry the fake
	// addresses and fill the tunnel sets.
	if (dns_redirect)
		s += '\t\tth dport 53 return\n';

	s += '\t\tip daddr @direct4 counter return\n';
	s += '\t\tip6 daddr @direct6 counter return\n';

	const tp4 = `meta l4proto { tcp, udp } meta mark set meta mark | ${mark} tproxy ip to 127.0.0.1:${C.TPROXY_PORT} counter accept`;
	// "meta nfproto ipv6" marks the lines dropped when IPv6 policy routing
	// cannot be set up (mayhem_net_up).
	const tp6 = `meta nfproto ipv6 meta l4proto { tcp, udp } meta mark set meta mark | ${mark} tproxy ip6 to [::1]:${C.TPROXY_PORT} counter accept`;

	if (cap) {
		if (fake_pool)
			s += `\t\tip daddr ${fake_pool} ${tp4}\n`;

		s += `\t\tip daddr @px4 ${tp4}\n`;

		if (v6)
			s += `\t\tip6 daddr @px6 ${tp6}\n`;
	}
	else {
		s += `\t\tmeta nfproto ipv4 ${tp4}\n`;

		if (v6)
			s += `\t\t${tp6}\n`;
	}

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

	// Devices with a DNS server of their own (8.8.8.8 and the like) ask
	// dnsmasq all the same.
	if (dns_redirect) {
		s += '\n\tchain dstnat {\n';
		s += '\t\ttype nat hook prerouting priority dstnat; policy accept;\n';
		s += '\t\tether saddr @bypass_mac return\n\t\tip saddr @bypass4 return\n\t\tip6 saddr @bypass6 return\n';
		s += '\t\tiifname @ifaces meta l4proto { tcp, udp } th dport 53 fib daddr type != local counter redirect to :53\n';
		s += '\t}\n';
	}

	return s + '}\n';
}

function build_nft(S, v6, sets, tunnels, dns_redirect, fake_pool, kdef, cap) {
	HOSTSETS = {};

	return with_hostsets(build_nft_text(S, v6, sets, tunnels, dns_redirect, fake_pool, kdef, cap));
}

// The fixed tail of a regexp rule as a domain: ^r+\d+\.googlevideo\.com$ ->
// googlevideo.com. Only when the tail starts at a label (after an escaped
// dot, or the whole anchored name) and the regexp ends with $; null otherwise.
export function regexp_tail(re) {
	if (substr(re, -1) != '$')
		return null;

	const s = substr(re, 0, length(re) - 1);
	let i = length(s) - 1, out = '';

	while (i >= 0) {
		const c = substr(s, i, 1);

		if (c == '.' && i > 0 && substr(s, i - 1, 1) == '\\') {
			out = '.' + out;
			i -= 2;
		}
		else if (match(c, /^[A-Za-z0-9-]$/)) {
			out = c + out;
			i--;
		}
		else
			break;
	}

	const whole = i == 0 && substr(s, 0, 1) == '^';

	if (substr(out, 0, 1) != '.' && !whole)
		return null;

	out = lc(replace(out, /^\.+/, ''));

	return (index(out, '.') > 0 && match(out, /^[a-z0-9-]+(\.[a-z0-9-]+)+$/)) ? out : null;
};

// Names whose DNS queries dnsmasq sends to xray, as dnsmasq matches them (a
// name and all its subdomains), from the rules of the sections whose traffic
// xray carries. A few more names than the rules take are fine: xray sends
// their traffic direct. Returns { names } or { why } when a rule cannot be
// spelled out so (keyword:, a regexp without a fixed tail, a category that is
// not spelled out on the router).
function dns_names(RLs, model) {
	const seen = {};
	const names = [];
	let why = null;

	const take = (rule, where) => {
		const m = match(rule, /^(domain|full|regexp|keyword):(.*)$/);

		if (!m) {
			why ??= `"${rule}" in ${where}`;
			return;
		}

		let n = m[2];

		if (m[1] == 'keyword')
			n = null;
		else if (m[1] == 'regexp')
			n = regexp_tail(n);
		else
			n = lc(n);

		if (n == null) {
			why ??= `${m[1]}:${m[2]} in ${where}`;
			return;
		}

		if (!seen[n]) {
			seen[n] = true;
			push(names, n);
		}
	};

	for (let x in RLs) {
		for (let d in x.RL.domains)
			if (substr(d, 0, 4) != 'ext:')
				take(d, `section "${x.name}"`);

		for (let g in x.RL.sites) {
			const list = model.geo?.domains?.[g.key];

			if (list == null) {
				why ??= `${g.text} in section "${x.name}" (${g.count ?? '?'} rules, more than dnsmasq takes)`;
				continue;
			}

			// An attribute picks part of the category: all of it goes to xray.
			for (let d in list)
				take(d, g.text);
		}
	}

	if (why)
		return { why: why };

	if (length(names) > C.DNS_SPLIT_MAX)
		return { why: `${length(names)} names, dnsmasq takes at most ${C.DNS_SPLIT_MAX}` };

	// A name under another one in the list adds nothing for dnsmasq.
	const out = [];

	for (let n in names) {
		let p = n, covered = false;

		while ((p = match(p, /^[^.]+\.(.+)$/)?.[1]) != null)
			if (seen[p]) {
				covered = true;
				break;
			}

		if (!covered)
			push(out, n);
	}

	return { names: out };
}

// dnsmasq server lines that send the queries for the names to one server.
function server_lines(names, server) {
	let out = '', line = '';

	for (let d in names) {
		if (length(line) + length(d) > 900) {
			out += `server=/${line}/${server}\n`;
			line = '';
		}

		line += (line != '' ? '/' : '') + d;
	}

	if (line != '')
		out += `server=/${line}/${server}\n`;

	return out;
}

// dnsmasq lines that put the addresses of the domains into two nftables sets
// (IPv4, IPv6). dnsmasq matches a domain together with its subdomains.
function nftset_lines(domains, set4, set6) {
	const sets = `4#inet#${C.NFT_TABLE}#${set4},6#inet#${C.NFT_TABLE}#${set6}`;
	let out = '', line = '';

	for (let d in domains) {
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
		v6: r?.v6 === true,
		proto: r?.proto ?? null
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
	const label = sec.pool ? 'server list' : `section "${name}"`;
	const nodes = [];

	if (sec.proxy_type == 'json') {
		const ob = json_outbound(sec.outbound_json ?? '');
		const why = refused_by_xray(ob);

		if (why)
			warn(`${label}: the JSON outbound is ${why}; skipped`);
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
				warn(`${label}: ${w}`);

			push(nodes, { name: r.name != '' ? r.name : `${name} ${n}`, outbound: r.outbound, source: 'link', link: l, usec: name });
		}
		catch (e) {
			warn(`${label}: link ${n}: ${e.message}; skipped`);
		}
	}

	// Network interfaces (WireGuard, AmneziaWG, OpenVPN...) as servers of the
	// group: xray sends the traffic straight into the interface.
	for (let iface in entries(sec.iface_node)) {
		const inf = iface_info(model, iface);

		push(nodes, {
			name: model.tunnel_labels?.[iface] ?? iface, outbound: iface_outbound(null, inf.device, inf.v6 ? null : 'ForceIPv4'),
			source: 'interface', iface: iface, tproto: inf.proto, device: inf.device
		});
	}

	const inc = name_regexp(sec.filter, `${label} filter`, warn);
	const exc = name_regexp(sec.exclude, `${label} exclude`, warn);

	for (let sub in entries(sec.subscription)) {
		const cache = model.subscriptions?.[sub];

		if (!cache) {
			warn(`${label}: subscription "${sub}" has not been downloaded yet`);
			continue;
		}

		for (let node in cache.nodes ?? []) {
			const nn = node.name ?? '';

			if ((inc && !match(nn, inc)) || (exc && match(nn, exc)))
				continue;

			try {
				const ob = node.outbound ? copy(node.outbound) : parse_link(node.link).outbound;

				// Filters see the provider's name; the user's name is shown.
				push(nodes, { name: model.aliases?.[sub]?.[nn] ?? nn, orig: nn, outbound: ob, source: sub });
			}
			catch (e) {
				warn(`${label}: server "${nn}" from "${sub}": ${e.message}; skipped`);
			}
		}
	}

	// One such server would keep xray from starting with every other one.
	const usable = [];

	for (let nd in nodes) {
		const why = refused_by_xray(nd.outbound);

		if (why)
			warn(`${label}: server "${nd.name}": ${why}; skipped`);
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
	const geo4 = [], geo6 = [], sites = [], geo_nosub = [];

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
			push(sites, { key: `${x.source}:${x.cat}`, attr: g.attr, text: text, count: x.count });
			return;
		}

		geoip.add(`ext:${x.file}:${g.neg ? '!' : ''}${x.cat}`);

		const c = model.geo?.cidrs?.[`${x.source}:${x.cat}`];

		if (c && !g.neg && !c.reverse) {
			for (let v in c.v4) push(geo4, v);
			for (let v in c.v6) push(geo6, v);
		}
		else
			push(geo_nosub, text);
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

		// Every rule of a list goes into xray's config as text and into its
		// matchers: a huge list takes hundreds of MB while the config is
		// built and read. Beyond the cap the rest of the list is left out.
		if (length(L.domains) + length(L.ips) > LIST_RULES_MAX) {
			warn(`section "${name}": list ${src} has ${length(L.domains) + length(L.ips)} rules, only the first ${LIST_RULES_MAX} are used; a geosite category of the same sites takes far less memory`);
			L.domains = slice(L.domains, 0, LIST_RULES_MAX);
			L.ips = slice(L.ips, 0, max(0, LIST_RULES_MAX - length(L.domains)));
		}

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
		geoip: geoip.items, geo4: geo4, geo6: geo6, sites: sites, geo_nosub: geo_nosub
	};
}

// Domains of a kernel-mode tunnel section in the form dnsmasq understands:
// domain: and full: rules and geosite categories (full: matches subdomains as
// well there). keyword: and regexp: only work through xray.
function kernel_domains(name, RL, model, warn, fallback) {
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

		if ((g.count ?? 0) > KERNEL_DOMAINS_MAX) {
			warn(`section "${name}": ${g.text} has ${g.count} domains, too many for dnsmasq: ${fallback ?? 'they work through xray only'}`);
			continue;
		}

		if (g.attr != '' || list == null) {
			warn(`section "${name}": ${g.text} ${fallback ? `cannot be spelled out for dnsmasq: ${fallback}` : 'works through xray only'}`);
			continue;
		}

		for (let d in list)
			take(d);
	}

	if (skipped)
		warn(`section "${name}": ${skipped} keyword/regexp rules ${fallback ? `cannot be spelled out for dnsmasq: ${fallback}` : 'work through xray only'}`);

	if (length(out.items) > KERNEL_DOMAINS_MAX) {
		warn(`section "${name}": ${length(out.items)} domains are too many for dnsmasq (at most ${KERNEL_DOMAINS_MAX}): ${fallback ?? 'they work through xray only'}`);
		return [];
	}

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

// Devices whose traffic Mayhem leaves alone: IPv4/IPv6 addresses or subnets
// and MAC addresses (settings.bypass).
function bypass_sets(S, warn) {
	const b4 = [], b6 = [], mac = [];

	for (let v in entries(S.bypass)) {
		v = lc(trim(v));

		if (match(v, /^([0-9a-f]{2}[:-]){5}[0-9a-f]{2}$/)) {
			uniq_push(mac, replace(v, /-/g, ':'));
			continue;
		}

		const r = norm_ip(v);

		if (r.error || r.geo)
			warn(`devices without Mayhem: "${v}" is not an address, subnet or MAC address, skipped`);
		else
			uniq_push(r.family == 4 ? b4 : b6, r.cidr);
	}

	return { bypass4: b4, bypass6: b6, bypass_mac: mac };
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
	// "By lists" sends to xray only what its rules route through a proxy,
	// unless the whole network is captured (settings.capture = all): domains
	// of proxy sections get fake addresses (FakeDNS), which is how the kernel
	// tells their traffic apart. Everything else stays in the kernel: xray
	// keeps no sessions (and no memory) for it.
	const capture_all = mode == 'global' || S.capture == 'all';
	const fake = fakedns || !capture_all;
	const log_level = index(LOG_LEVELS, S.log_level) >= 0 ? S.log_level : 'warning';

	// The first outbound takes traffic that no rule names and traffic routed
	// to a tag that does not exist (a server being replaced): it is dropped,
	// never sent direct by mistake.
	const outbounds = [
		{ tag: 'block', protocol: 'blackhole', settings: {} },
		{ tag: 'direct', protocol: 'freedom', settings: {}, streamSettings: { sockopt: { domainStrategy: F.freedom } } },
		{ tag: 'direct-udp', protocol: 'freedom', settings: { userLevel: UDP_LEVEL }, streamSettings: { sockopt: { domainStrategy: F.freedom } } }
	];

	const sets = { block4: uset(), block6: uset(), direct4: uset(), direct6: uset() };
	const geo_pending = {};
	const geo_files = [];
	const lists_missing = [];

	const proxy_domains = uset();
	const block_domains = uset();
	const excl_domains = uset();
	const px4 = uset(), px6 = uset();	// subnets that reach xray when only the lists are captured

	// IP rules of a section whose traffic goes through xray.
	const to_xray = (sn, RL) => {
		px4.add_all(RL.ip4);
		px4.add_all(RL.geo4);
		px6.add_all(RL.ip6);
		px6.add_all(RL.geo6);

		if (!capture_all)
			for (let g in RL.geo_nosub)
				warn(`section "${sn}": ${g} only works when all traffic goes to Xray (Routing → Capture)`);
	};
	const tun_domains4 = uset();		// tunnel sections without IPv6: no AAAA answers
	const tun_domains = uset();
	const xray_dns = [];		// { name, RL }: sections whose names dnsmasq sends to xray
	const tunnels = [];			// kernel-mode tunnel sections
	const tun_all = [];			// every tunnel section, for the watchdog
	const tun_rules = [];
	let tun_index = 0;
	const routed = [];			// sections the rest-into-a-kernel-tunnel mode must respect

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
				to_xray(name, RL);
				push(xray_dns, { name: name, RL: RL });
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

			const smode = index([ 'manual', 'fallback' ], sec.select) >= 0 ? sec.select : 'auto';
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
					iface: nodes[i].iface,
					tproto: nodes[i].tproto,
					device: nodes[i].device,
					orig: nodes[i].orig,
					// the key itself and its UCI section: LuCI edits it in place
					link: nodes[i].link,
					usec: nodes[i].usec
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
				// A tunnel is also found by its interface: renaming it keeps the choice.
				const byname = (n) => filter(sinfo.nodes, (x) => x.name == n)[0] ??
					filter(sinfo.nodes, (x) => (x.iface != null && x.iface == n) || (x.orig != null && x.orig == n))[0];
				let pick = null;

				if (smode == 'manual') {
					pick = byname(sec.selected);

					if (sec.selected && !pick)
						warn(`section "${name}": selected server "${sec.selected}" is gone, using the first one`);

					pick ??= sinfo.nodes[0];
					sinfo.selected = pick.tag;
				}
				// A fallback chain: server 1, while it works; then server 2...
				// The scheduler (fallback.uc) moves the choice along the
				// chain; here it starts with the server it chose last, if that
				// is still in the chain, or with the first.
				else if (smode == 'fallback') {
					let chain = [];

					for (let c in entries(sec.chain)) {
						const n = byname(c);

						if (!n)
							warn(`section "${name}": server "${c}" of the fallback chain is gone`);
						else if (index(chain, n.tag) < 0)
							push(chain, n.tag);
					}

					if (!length(chain))
						chain = map(sinfo.nodes, (n) => n.tag);

					const now = R.fallback?.[name];

					pick = filter(sinfo.nodes, (n) => n.tag == (index(chain, now) >= 0 ? now : chain[0]))[0];
					sinfo.chain = chain;
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
				const watched = smode != 'manual';
				const balancer = {
					tag: bal,
					selector: [ `n-${name}-` ],
					strategy: { type: watched ? 'leastPing' : 'random' }
				};

				// The fallback (no server checked yet, or none answers) is a
				// copy of the pinned or first server under a tag of its own:
				// the balancer stays the same when the servers change.
				if (watched) {
					const src = filter(outbounds, (o) => o.tag == (pick ?? sinfo.nodes[0]).tag)[0];

					push(outbounds, { ...copy(src), tag: `f-${name}` });
					balancer.fallbackTag = `f-${name}`;
				}

				push(balancers, balancer);

				if (pick)
					push(overrides, `${bal} ${pick.tag}`);

				if (watched)
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
			to_xray(name, RL);
			push(xray_dns, { name: name, RL: RL });
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

			block_domains.add_all(domains);
			push(xray_dns, { name: name, RL: RL });

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
			push(xray_dns, { name: name, RL: RL });

			if (kernel)
				(tv6 ? tun_domains : tun_domains4).add_all(domains);
			else if (fake) {
				proxy_domains.add_all(domains);
				to_xray(name, RL);
			}
			else
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

		push(routed, { type: info.type, name: name, RL: RL });
		info.ok = true;
	}

	// --- default route ------------------------------------------------------

	// The default section: the rest of the traffic in "everything through
	// proxy" mode, remote DNS and downloads go through its active server.
	const want = S.default_section;
	const first_iface = keys(iface_targets)[0];
	let default_name = null;

	// A main section without servers of its own means the server list itself.
	const pooled = filter(model.sections ?? [], (x) => x['.name'] == want && x.use_pool)[0];

	if (pooled && proxy_targets.pool)
		default_name = 'pool';
	else if (want && (proxy_targets[want] || iface_targets[want]))
		default_name = want;
	else {
		default_name = first_proxy ?? first_iface;

		if (want && default_name && want != 'pool')
			warn(`the main section "${want}" does not work, using ${default_name == 'pool' ? 'the server list' : `"${default_name}"`}`);
	}

	const default_target = default_name ? (proxy_targets[default_name] ?? iface_targets[default_name]) : null;
	let final_target = { outboundTag: 'direct' };

	if (mode == 'global') {
		if (default_target)
			final_target = default_target;
		else
			fail('the rest of the traffic needs a server: add one or a subscription on the Server list page, or turn "The rest of the traffic through the tunnel" off');
	}

	// A tunnel chosen by hand among the servers of the main section takes
	// the rest of the traffic in the kernel as well: xray then carries only
	// what the rules send to it, and keeps far less memory. The watchdog
	// sets its route and leaves the balancer (and the choice) alone.
	if (mode == 'global' && default_name && !iface_targets[default_name]) {
		const ds = state.sections[default_name];
		const pick = ds?.selected ?? ds?.override;
		const n = pick ? filter(ds.nodes ?? [], (x) => x.tag == pick)[0] : null;

		if (n?.iface && R.dnsmasq_nftset === false)
			warn(`tunnel ${n.iface} carries the rest of the traffic through xray; with dnsmasq-full it would go in the kernel and xray would need far less memory`);
		else if (n?.iface) {
			const inf = iface_info(model, n.iface);

			if (++tun_index > C.TUN_MAX)
				warn(`tunnel ${n.iface}: at most ${C.TUN_MAX} tunnels can work in kernel mode, it works through xray`);
			else {
				const t = { name: default_name, index: tun_index, device: inf.device, v6: v6 && inf.v6, ip4: [], ip6: [], domains: [] };

				push(tunnels, t);
				push(tun_all, { name: default_name, device: inf.device, mark: tun_mark(t.index), table: C.TUN_TABLE + t.index, v6: t.v6, keep_bal: true });
				ds.kernel = n.iface;
			}
		}
	}

	// Without nftset support in dnsmasq, kernel sections only get the
	// subnets from their rules; domains go through xray.
	const nftset = length(tunnels) && R.dnsmasq_nftset !== false;
	const dns_redirect = is_true(D.hijack ?? '1');

	if (length(tunnels) && !nftset)
		warn('kernel mode needs dnsmasq-full (nftset support): domains of tunnel sections go through xray until it is installed');

	// The main section is a tunnel in kernel mode: the rest of the traffic
	// goes into it in the kernel, past xray. Proxy sections still reach xray
	// and exclusions stay out by subnets and by the addresses of their
	// domains (dnsmasq), which is why it needs dnsmasq-full.
	let kdef = null;
	const kdef_tun = mode == 'global' ? filter(tunnels, (t) => t.name == default_name)[0] : null;

	if (kdef_tun && !nftset)
		warn(`the rest of the traffic goes into "${default_name}" through xray until dnsmasq-full is installed`);
	else if (kdef_tun) {
		const px4 = uset(), px6 = uset(), pxd = uset(), dird = uset(), blkd = uset();
		const into = `they go into "${default_name}"`;

		for (let r in routed) {
			const toxray = r.type == 'proxy' || r.type == 'interface';

			if (toxray) {
				px4.add_all(r.RL.ip4);
				px4.add_all(r.RL.geo4);
				px6.add_all(r.RL.ip6);
				px6.add_all(r.RL.geo6);
			}

			// FakeDNS answers proxy domains with its own addresses: the
			// pool is sent to xray as a whole.
			if (toxray && fake)
				continue;

			const doms = kernel_domains(r.name, r.RL, model, warn,
				r.type == 'block' ? `they are not blocked, ${into}` : into);

			(toxray ? pxd : r.type == 'block' ? blkd : dird).add_all(doms);
		}

		kdef = {
			name: default_name, mark: kdef_tun.mark ?? tun_mark(kdef_tun.index), v6: kdef_tun.v6,
			px4: px4.items, px6: px6.items, pxd: pxd.items, dird: dird.items, blkd: blkd.items,
			torrent: is_true(S.torrent_direct ?? '0'), no_quic: is_true(S.block_quic ?? '0')
		};
	}

	// --- DNS ----------------------------------------------------------------

	if (length(R.dnsmasq_servers ?? []))
		warn(`dnsmasq also asks the DNS servers of its own settings (${join(', ', R.dnsmasq_servers)}): proxied sites may get their real address from them and go direct; remove them under Network → DHCP and DNS → Forwards`);

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

	// By lists, dnsmasq asks xray only about the names of the rules and the
	// provider (or the plain domestic servers) about everything else: most
	// queries of the network never reach xray, which kept a session (~30 KB,
	// a few goroutines, 0.6 ms of CPU on x86) for each, and ordinary sites
	// resolve even while xray restarts. Not possible with rules dnsmasq
	// cannot match (keyword:, some regexp:) or with domestic DoH/TCP: then
	// every query goes through xray, as in "everything through the proxy".
	let split = null;
	let split_why = null;
	let upstream = null;		// dnsmasq lines for the rest, null = the provider's

	if (mode == 'lists') {
		const user = filter(entries(D.domestic), (x) => !dns_server(x).error && index(own, dns_server(x).host) < 0);

		if (length(user)) {
			upstream = '';

			for (let d in domestic) {
				if (!is_ip(d.address)) {
					split_why = `the domestic DNS ${d.address} is not a plain address`;
					break;
				}

				upstream += `server=${d.address}${d.port ? `#${d.port}` : ''}\n`;
			}
		}

		if (!split_why) {
			const r = dns_names(xray_dns, model);

			if (r.why)
				split_why = r.why;
			else
				split = r.names;
		}
	}

	const servers = [];
	const host_rules = [ ...server_hosts, ...node_hosts ];

	if (length(host_rules))
		for (let d in domestic)
			push(servers, ns(d, { domains: host_rules, skipFallback: true }));

	if (mode == 'lists') {
		// Fake addresses need no remote server: the proxy resolves the
		// domain on its side. Each DNS server with domains is a matcher of
		// its own in xray's memory, so there are as few as possible.
		// With dnsmasq sending only the names of the rules, every query
		// that reaches xray gets a fake address: no list of domains here.
		// It comes after the servers with domains (tunnels) and before the
		// domestic one, which xray's own lookups use (they skip FakeDNS).
		const fake_all = fake && split != null;

		if (fake && !fake_all) {
			const fdoms = !capture_all ? [ ...proxy_domains.items, ...block_domains.items ] : proxy_domains.items;

			if (length(fdoms))
				push(servers, { address: 'fakedns', domains: fdoms, skipFallback: true });
		}
		else if (!fake && length(proxy_domains.items))
			for (let r in remote)
				push(servers, ns(r, { domains: proxy_domains.items, skipFallback: true }));

		// Tunnel sections: real addresses (dnsmasq puts them into the
		// kernel sets), no IPv6 answers when the tunnel has no IPv6.
		if (length(tun_domains4.items))
			for (let r in remote)
				push(servers, ns(r, { domains: tun_domains4.items, skipFallback: true, queryStrategy: 'UseIPv4' }));

		if (length(tun_domains.items))
			for (let r in remote)
				push(servers, ns(r, { domains: tun_domains.items, skipFallback: true }));

		if (fake_all)
			push(servers, { address: 'fakedns' });

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

		// The rest into a kernel tunnel needs real addresses: FakeDNS only
		// for proxy domains, whose fake addresses go to xray.
		if (fake && kdef) {
			if (length(proxy_domains.items))
				push(servers, { address: 'fakedns', domains: proxy_domains.items, skipFallback: true });
		}
		else if (fake)
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

	// Direct UDP leaves through "direct-udp" (short idle timeout, see UDP_IDLE).
	const direct_udp = (r) => {
		if (r.outboundTag == 'direct')
			push(rules, intercepted({ ...r, network: 'udp', outboundTag: 'direct-udp' }));

		push(rules, intercepted(r));
	};

	// Without QUIC browsers fall back to TCP, which proxies carry better.
	if (is_true(S.block_quic))
		push(rules, intercepted({ network: 'udp', port: '443', outboundTag: 'block' }));

	for (let r in block_rules)
		push(rules, intercepted(r));

	// BitTorrent is recognized by sniffing its first packets.
	if (is_true(S.torrent_direct))
		direct_udp({ protocol: [ 'bittorrent' ], outboundTag: 'direct' });

	for (let r in tun_rules)
		push(rules, intercepted(r));

	for (let r in section_rules)
		push(rules, intercepted(r));

	direct_udp({ network: 'tcp,udp', ...final_target });

	for (let r in helper_rules)
		push(rules, r);

	// --- assemble -----------------------------------------------------------

	const sniff = [ 'http', 'tls', 'quic' ];

	if (fake)
		unshift(sniff, 'fakedns');

	// FakeDNS in global mode gives every domain a fake address, so xray only
	// knows the domain and IP rules (geoip:ru in an exclusion, say) never
	// match: let xray resolve the domain when it reaches such a rule. The
	// lookup skips FakeDNS and is cached by xray's DNS. In lists mode only
	// listed domains get fake addresses, and their domain rules match first.
	const ip_strategy = (fake && mode == 'global' && length(filter(rules, (r) => r.ip))) ? 'IPOnDemand' : 'AsIs';

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
			// '1' is DNS_LEVEL, '2' is UDP_LEVEL
			levels: { '1': { connIdle: DNS_IDLE }, '2': { connIdle: UDP_IDLE } },
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

	// Automatic choice: each server is checked once per interval, at a random
	// moment of it. The plain observatory checks all of them at once: with 150
	// servers xray took up to 20 MB more at every interval (37 MB instead of
	// 16). At start every server is checked at once, for a quick choice.
	// The same checks: GET, 5 s timeout; a server counts as working when its
	// last check passed, and leastPing picks the fastest such.
	if (length(observe)) {
		const iv = match(S.probe_interval ?? '', /^[0-9]+[smh]$/) ? S.probe_interval : C.DEFAULT_PROBE_INTERVAL;
		const url = match(S.probe_url ?? '', /^https?:\/\//) ? S.probe_url : C.DEFAULT_PROBE_URL;

		xray.burstObservatory = {
			subjectSelector: observe,
			pingConfig: { destination: url, interval: iv, sampling: 1, timeout: '5s', httpMethod: 'GET' }
		};
	}

	if (fake)
		xray.fakedns = [ { ipPool: C.FAKEDNS_POOL, poolSize: C.FAKEDNS_POOL_SIZE } ];

	// What running xray cannot change: everything but the servers and the
	// routing. procd restarts xray when this changes; otherwise live.uc swaps
	// the servers and the routing in place. With "only matched lists" a new server host needs nothing from
	// DNS: names outside the lists go to the domestic DNS anyway.
	const key = copy(xray);

	key.outbounds = filter(key.outbounds, (o) => !match(o.tag, /^[nf]-/));
	// Rules and balancers are replaced in running xray as a whole (live.uc):
	// the main section, the order of a fallback chain, new rules of a section.
	delete key.routing.rules;
	delete key.routing.balancers;

	for (let ib in key.inbounds)
		if (ib.tag == 'helper-in')
			ib.settings.accounts = filter(ib.settings.accounts, (a) => !match(a.user, /^n-/));

	if (mode == 'lists' && length(host_rules))
		for (let i = 0; i < length(domestic); i++)
			key.dns.servers[i].domains = server_hosts;

	state.default_section = default_name;
	state.kernel_default = kdef ? kdef.name : null;
	state.geo_pending = geo_pending;
	state.lists_missing = lists_missing;
	state.generated = R.now ?? time();
	state.mode = mode;
	state.capture = capture_all ? 'all' : 'lists';
	state.dns = split != null ? { split: true, names: length(split) } : { split: false, why: split_why };
	state.probe_url = xray.burstObservatory?.pingConfig?.destination ?? (match(S.probe_url ?? '', /^https?:\/\//) ? S.probe_url : C.DEFAULT_PROBE_URL);

	return {
		ok: !length(st.errors),
		mode: mode,
		xray: xray,
		nft: build_nft(S, v6, {
			ifaces: entries(S.interface),
			...bypass_sets(S, warn),
			block4: sets.block4.items, block6: sets.block6.items,
			direct4: sets.direct4.items, direct6: sets.direct6.items
		}, tunnels, dns_redirect, fake ? C.FAKEDNS_POOL : null, kdef,
			capture_all ? null : { px4: px4.items, px6: v6 ? px6.items : [] }),
		// Which servers dnsmasq asks (xray, or the provider's while xray is
		// down) is in servers-file: dnsmasq reads it again on SIGHUP.
		// What dnsmasq asks while xray works: "@ISP@" stands for the
		// provider's servers, which the service puts in when it switches.
		dns_xray: split != null
			? (upstream ?? '@ISP@\n') + server_lines(split, `127.0.0.1#${C.DNS_PORT}`)
			: `server=127.0.0.1#${C.DNS_PORT}\n`,
		dnsmasq: `no-resolv\nservers-file=${C.DNS_SERVERS}\n` +
			(nftset ? join('', map(tunnels, (t) => nftset_lines(t.domains, `tun_${t.name}_d4`, `tun_${t.name}_d6`))) : '') +
			(kdef ? nftset_lines(kdef.blkd, 'blk_d4', 'blk_d6') + nftset_lines(kdef.dird, 'dir_d4', 'dir_d6') +
				nftset_lines(kdef.pxd, 'px_d4', 'px_d6') : ''),
		// "section device mark table v6" per tunnel section; mark and table are
		// "-" in xray mode.
		tunnels: join('', map(tun_all, (t) => `${t.name} ${t.device} ${t.mark} ${t.table} ${t.v6 ? 1 : 0}${t.keep_bal ? ' 0' : ''}\n`)),
		key: key,
		memlimit_mib: memlimit_mib(S, R),
		ipv6: v6,
		state: state,
		overrides: overrides,
		geo_files: geo_files,
		status: st
	};
};
