// Mayhem: reads /etc/config/mayhem and runtime facts into the model consumed
// by mayhem.build. Only this module touches UCI and the live system.
// Loaded with require() so that tests without the uci module can skip it.

'use strict';

import { cursor } from 'uci';
import { readfile, writefile, access, stat, mkdir, lsdir, unlink, popen } from 'fs';
import { SUBS_DIR, UCI_DIR, GEO_DIR, LISTS_DIR, RUN_DIR, DNS_SPLIT_MAX } from 'mayhem.const';
import { is_true, entries, list_key, norm_ip, norm_domain, is_ip, dnsmasq_nftset } from 'mayhem.rules';
import { resolve, geoip_cidrs, geosite_domains, KERNEL_DOMAINS_MAX } from 'mayhem.geo';

const RESOLV_FILES = [ '/tmp/resolv.conf.d/resolv.conf.auto', '/tmp/resolv.conf.auto' ];

function wan_dns() {
	const out = [];

	for (let f in RESOLV_FILES) {
		const data = readfile(f);

		if (!data)
			continue;

		for (let line in split(data, '\n')) {
			const m = match(line, /^[[:space:]]*nameserver[[:space:]]+([^[:space:]#%]+)/);

			if (m && index(out, m[1]) < 0)
				push(out, m[1]);
		}

		if (length(out))
			break;
	}

	return out;
}

function mem_total_kb() {
	const m = match(readfile('/proc/meminfo') ?? '', /MemTotal:[[:space:]]+([0-9]+)/);

	return m ? int(m[1]) : null;
}

function command(cmd) {
	const p = popen(cmd, 'r');

	if (!p)
		return null;

	const out = p.read('all');

	p.close();

	return out;
}

// State of the network interfaces that tunnel sections use (netifd names).
function ifaces(names) {
	const out = {};
	const net = cursor(UCI_DIR);
	const has_net = net.load('network');
	const proto = (n) => has_net ? net.get('network', n, 'proto') : null;

	for (let n in names) {
		if (!match(n, /^[A-Za-z0-9_.-]+$/))
			continue;

		let st = null;

		try {
			st = json(command(`ifstatus ${n} 2>/dev/null`) ?? '');
		}
		catch (e) {
			st = null;
		}

		if (type(st) != 'object') {
			// Not a netifd interface: maybe a plain device name.
			out[n] = { device: n, up: access(`/sys/class/net/${n}`) == true, v6: false, proto: proto(n) };
			continue;
		}

		out[n] = {
			device: st.l3_device ?? st.device ?? n,
			up: st.up == true,
			v6: length(st['ipv6-address'] ?? []) > 0,
			// From the config: a protocol netifd has not loaded runs as "none".
			proto: proto(n) ?? st.proto
		};
	}

	return out;
}

// Addresses of the router itself (static interfaces): as a domestic DNS server
// they stand for the provider's servers.
function router_ips() {
	const out = [];

	try {
		const c = cursor(UCI_DIR);

		c.load('network');
		c.foreach('network', 'interface', (s) => {
			for (let a in entries(s.ipaddr)) {
				const ip = split(a, '/')[0];

				if (is_ip(ip))
					push(out, ip);
			}
		});
	}
	catch (e) {
		// no network config (tests)
	}

	return out;
}

function fallback_now() {
	try {
		return json(readfile(`${RUN_DIR}/fallback.json`) ?? '');
	}
	catch (e) {
		return null;
	}
}

// Upstream servers set in dnsmasq's own settings (/etc/config/dhcp, "list
// server"). dnsmasq asks them next to xray, so a proxied domain may get its
// real address from them and go direct. Servers for one domain
// (/lan/192.168.1.5) do not matter.
function dnsmasq_servers() {
	const out = [];

	try {
		const c = cursor(UCI_DIR);

		c.load('dhcp');
		c.foreach('dhcp', 'dnsmasq', (s) => {
			for (let v in entries(s.server))
				if (substr(v, 0, 1) != '/' && index(out, v) < 0)
					push(out, v);
		});
	}
	catch (e) {
		return [];
	}

	return out;
}

// IPv4 addresses of devices by MAC: static leases (DHCP and DNS → Static
// leases), then the current leases of dnsmasq. A section limited to some
// devices finds a device given by MAC through them (xray sees addresses).
function leases() {
	const out = {};
	const mac_re = /^([0-9a-f]{2}:){5}[0-9a-f]{2}$/;

	try {
		const c = cursor(UCI_DIR);

		c.load('dhcp');
		c.foreach('dhcp', 'host', (h) => {
			if (!is_ip(h.ip ?? ''))
				return;

			for (let m in split(join(' ', entries(h.mac)), /[ ,]+/)) {
				m = lc(replace(m, /-/g, ':'));

				if (match(m, mac_re))
					out[m] = h.ip;
			}
		});
	}
	catch (e) {
		// no dhcp config (tests)
	}

	for (let l in split(readfile(getenv('MAYHEM_LEASES') ?? '/tmp/dhcp.leases') ?? '', '\n')) {
		const f = split(l, ' ');
		const m = lc(f[1] ?? '');

		if (match(m, mac_re) && is_ip(f[2] ?? '') && index(f[2], ':') < 0)
			out[m] ??= f[2];
	}

	return out;
}

function runtime(sections) {
	const names = [];

	for (let s in sections ?? []) {
		if (!is_true(s.enabled ?? '1'))
			continue;

		if (s.type == 'interface' && s.interface)
			push(names, s.interface);

		for (let n in entries(s.iface_node))
			push(names, n);
	}

	return {
		wan_dns: wan_dns(),
		ipv6: access('/proc/net/if_inet6') == true,
		mem_total_kb: mem_total_kb(),
		router_ips: router_ips(),
		ifaces: ifaces(names),
		// tunnels in kernel mode and excluded domains in global mode need it
		dnsmasq_nftset: dnsmasq_nftset(command('dnsmasq --version 2>/dev/null')),
		// the servers fallback chains use now (fallback.uc): { section: tag }
		fallback: fallback_now(),
		dnsmasq_servers: dnsmasq_servers(),
		leases: leases()
	};
}

function read_json(path) {
	try {
		return json(readfile(path) ?? '');
	}
	catch (e) {
		return null;
	}
}

// Geo sources in configuration order, with the index of their last download.
function geo_sources(c) {
	const out = [];

	c.foreach('mayhem', 'geo_source', (s) => {
		const idx = read_json(`${GEO_DIR}/${s['.name']}.json`);

		push(out, {
			name: s['.name'],
			kind: s.kind == 'geoip' ? 'geoip' : 'geosite',
			enabled: is_true(s.enabled ?? '1'),
			url: s.url,
			index: type(idx) == 'object' ? idx : null
		});
	});

	return out;
}

// Subnets of the geoip categories that sections use: they go into nftables
// sets. Direct and blocked traffic never reaches xray, and with only the
// lists captured, proxied subnets are how the kernel knows what to send to it.
function geo_cidrs(sections, sources) {
	const per_source = {};
	const out = {};

	for (let sec in sections) {
		if (!is_true(sec.enabled ?? '1'))
			continue;

		for (let i in entries(sec.ip)) {
			const r = norm_ip(i);

			if (!r.geo || r.geo.neg)
				continue;

			const x = resolve(sources, r.geo);

			if (x.state == 'ready') {
				per_source[x.source] ??= [];
				push(per_source[x.source], x.cat);
			}
		}
	}

	// Parsing tens of thousands of subnets takes seconds on a router: the
	// result is cached in RAM until the geo file changes.
	const cache_dir = `${RUN_DIR}/geo-cache`;
	const used = {};

	mkdir(cache_dir, 0700);

	for (let src in keys(per_source)) {
		const path = `${GEO_DIR}/${src}.dat`;
		const st = stat(path);
		const todo = [];

		if (!st)
			continue;

		for (let cat in per_source[src]) {
			const cf = `${src}.${cat}.${st.size}-${st.mtime}.json`;

			used[cf] = true;

			const c = read_json(`${cache_dir}/${cf}`);

			if (type(c) == 'object')
				out[`${src}:${cat}`] = c;
			else
				push(todo, cat);
		}

		if (!length(todo))
			continue;

		const res = geoip_cidrs(path, todo);

		for (let cat in keys(res)) {
			out[`${src}:${cat}`] = res[cat];
			writefile(`${cache_dir}/${src}.${cat}.${st.size}-${st.mtime}.json`, sprintf('%J', res[cat]));
		}
	}

	for (let f in lsdir(cache_dir) ?? [])
		if (!used[f] && !match(f, /\.domains\.json$/))
			unlink(`${cache_dir}/${f}`);

	return out;
}

// Domains of the geosite categories that kernel-mode tunnel sections use:
// dnsmasq needs them spelled out. Cached in RAM like the subnets. With the
// rest of the traffic going into a kernel tunnel (all), the categories of
// every section: their addresses must be told apart in the kernel.
function geo_domains(sections, sources, all, split) {
	const per_source = {};
	const out = {};
	const used = {};
	const cache_dir = `${RUN_DIR}/geo-cache`;

	for (let sec in sections) {
		if (!is_true(sec.enabled ?? '1'))
			continue;

		// Kernel tunnels need their categories spelled out for dnsmasq's
		// nftset; other sections only small ones, for the names dnsmasq
		// sends to xray (DNS_SPLIT_MAX).
		const kernel = sec.type == 'interface' && (sec.route_mode ?? 'kernel') != 'xray';
		const most = kernel ? KERNEL_DOMAINS_MAX : DNS_SPLIT_MAX;

		if (!all && !kernel && !split)
			continue;

		for (let d in entries(sec.domain)) {
			const r = norm_domain(d);

			if (!r.geo || r.geo.attr != '')
				continue;

			const x = resolve(sources, r.geo);

			// Not spelled out at all when too big for dnsmasq (the generator
			// says so): a million domains would not fit in RAM here either.
			if (x.state == 'ready' && (x.count ?? 0) <= (all ? KERNEL_DOMAINS_MAX : most)) {
				per_source[x.source] ??= [];
				push(per_source[x.source], x.cat);
			}
		}
	}

	mkdir(cache_dir, 0700);

	for (let src in keys(per_source)) {
		const path = `${GEO_DIR}/${src}.dat`;
		const st = stat(path);
		const todo = [];

		if (!st)
			continue;

		for (let cat in per_source[src]) {
			const cf = `${src}.${cat}.${st.size}-${st.mtime}.domains.json`;
			const c = read_json(`${cache_dir}/${cf}`);

			used[cf] = true;

			if (type(c) == 'array')
				out[`${src}:${cat}`] = c;
			else
				push(todo, cat);
		}

		if (!length(todo))
			continue;

		const res = geosite_domains(path, todo);

		for (let cat in keys(res)) {
			out[`${src}:${cat}`] = res[cat];
			writefile(`${cache_dir}/${src}.${cat}.${st.size}-${st.mtime}.domains.json`, sprintf('%J', res[cat]));
		}
	}

	for (let f in lsdir(cache_dir) ?? [])
		if (!used[f] && match(f, /\.domains\.json$/))
			unlink(`${cache_dir}/${f}`);

	return out;
}

// Contents of the rule lists that sections use, keyed by URL or path.
function lists(sections) {
	const out = {};

	for (let sec in sections) {
		if (!is_true(sec.enabled ?? '1'))
			continue;

		for (let u in entries(sec.list_url))
			out[u] ??= readfile(`${LISTS_DIR}/${list_key(u)}.lst`);

		for (let f in entries(sec.list_file))
			out[f] ??= readfile(f);
	}

	return out;
}

// A proxy section without servers of its own uses the server list. Older
// configurations have no "servers" option: links, subscriptions, a JSON
// outbound or tunnels as servers make them sections with their own servers.
function own_servers(s) {
	if (s.servers == 'own' || s.servers == 'pool')
		return s.servers == 'own';

	return length(entries(s.link)) > 0 || length(entries(s.subscription)) > 0 ||
		s.proxy_type == 'json' || length(entries(s.iface_node)) > 0;
}

// The server list as a proxy section of its own, first, without rules: the
// servers added by key, those of every enabled subscription and the tunnels
// chosen to be servers too.
// Protocols of network interfaces that are tunnels to somewhere else.
const TUNNEL_PROTOS = [ 'amneziawg', 'wireguard', 'openvpn', 'openconnect', 'vpnc', 'l2tp', 'pptp' ];

// Every tunnel interface is a server of the server list, unless its
// "config tunnel '<interface>'" says "option server '0'"; plus any named in
// the list's own iface_node.
function pool_tunnels(c, p) {
	const out = [];
	const add = (n) => {
		if (index(out, n) < 0 && c.get('mayhem', n, 'server') != '0')
			push(out, n);
	};

	const net = cursor(UCI_DIR);

	if (net.load('network'))
		net.foreach('network', 'interface', (i) => {
			if (index(TUNNEL_PROTOS, i.proto) >= 0 && i.disabled != '1')
				add(i['.name']);
		});

	for (let n in entries(p.iface_node))
		add(n);

	return out;
}

function pool_section(c) {
	const p = c.get_all('mayhem', 'pool');

	if (!p)
		return null;

	const subs = [];

	c.foreach('mayhem', 'subscription', (s) => {
		if (is_true(s.enabled ?? '1'))
			push(subs, s['.name']);
	});

	return {
		'.name': 'pool', '.type': 'pool', type: 'proxy', enabled: '1', pool: true,
		link: p.link, subscription: subs, iface_node: pool_tunnels(c, p),
		select: p.select, selected: p.selected, override: p.override, chain: p.chain
	};
}

function load_model() {
	const c = cursor(UCI_DIR);

	c.load('mayhem');

	const sections = [];
	const pool = pool_section(c);

	if (pool)
		push(sections, pool);

	c.foreach('mayhem', 'section', (s) => {
		if (s['.name'] == 'pool')
			return;

		if (pool && (s.type ?? 'proxy') == 'proxy' && !own_servers(s))
			s = { ...s, use_pool: true };

		push(sections, s);
	});

	// Servers of a subscription the user renamed: "original<TAB>new name".
	const aliases = {};

	c.foreach('mayhem', 'subscription', (s) => {
		for (let a in entries(s.alias)) {
			const i = index(a, '\t');

			if (i > 0) {
				aliases[s['.name']] ??= {};
				aliases[s['.name']][substr(a, 0, i)] = substr(a, i + 1);
			}
		}
	});

	// Servers the user deleted from a subscription (the provider's names);
	// they stay out of the list when the subscription is updated.
	const hidden = {};

	c.foreach('mayhem', 'subscription', (s) => {
		for (let h in (type(s.hidden) == 'array' ? s.hidden : (s.hidden != null ? [ s.hidden ] : []))) {
			hidden[s['.name']] ??= {};
			hidden[s['.name']][h] = true;
		}
	});

	// Downloaded subscriptions, keyed by the subscription section name.
	const subscriptions = {};

	c.foreach('mayhem', 'subscription', (s) => {
		try {
			const cache = json(readfile(`${SUBS_DIR}/${s['.name']}.json`) ?? '');

			if (type(cache) == 'object')
				subscriptions[s['.name']] = cache;
		}
		catch (e) {
			// not downloaded yet
		}
	});

	const sources = geo_sources(c);
	const settings = c.get_all('mayhem', 'settings') ?? {};

	// Names the user gave tunnels ("config tunnel '<interface>'").
	const tunnel_labels = {};

	c.foreach('mayhem', 'tunnel', (t) => {
		if (t.label != null && t.label != '')
			tunnel_labels[t['.name']] = t.label;
	});

	// The rest of the traffic may go into a kernel tunnel: the main section
	// (or, without one, the first tunnel the generator would fall back to)
	// is a tunnel section in kernel mode.
	// Spelled-out categories of every section are also needed by lists:
	// dnsmasq then sends only their names to xray (see dns_names in build).
	const kernel_rest = settings.mode == 'global' && length(filter(sections, (s) =>
		is_true(s.enabled ?? '1') && s.type == 'interface' && (s.route_mode ?? 'kernel') != 'xray' &&
		(settings.default_section == null || settings.default_section == s['.name']))) > 0;

	return {
		subscriptions: subscriptions,
		geo: { sources: sources, cidrs: geo_cidrs(sections, sources), domains: geo_domains(sections, sources, kernel_rest, settings.mode != 'global') },
		lists: lists(sections),
		settings: settings,
		tunnel_labels: tunnel_labels,
		aliases: aliases,
		hidden: hidden,
		dns: c.get_all('mayhem', 'dns') ?? {},
		sections: sections,
		runtime: runtime(sections)
	};
}

return { load_model, runtime, own_servers };
