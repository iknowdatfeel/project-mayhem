// Mayhem: reads /etc/config/mayhem and runtime facts into the model consumed
// by mayhem.build. Only this module touches UCI and the live system.
// Loaded with require() so that tests without the uci module can skip it.

'use strict';

import { cursor } from 'uci';
import { readfile, writefile, access, stat, mkdir, lsdir, unlink, popen } from 'fs';
import { SUBS_DIR, UCI_DIR, GEO_DIR, LISTS_DIR, RUN_DIR } from 'mayhem.const';
import { is_true, entries, list_key, norm_ip, norm_domain } from 'mayhem.rules';
import { resolve, geoip_cidrs, geosite_domains } from 'mayhem.geo';

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
			out[n] = { device: n, up: access(`/sys/class/net/${n}`) == true, v6: false };
			continue;
		}

		out[n] = {
			device: st.l3_device ?? st.device ?? n,
			up: st.up == true,
			v6: length(st['ipv6-address'] ?? []) > 0
		};
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
		ifaces: ifaces(names),
		dnsmasq_nftset: length(names) ? index(command('dnsmasq --version 2>/dev/null') ?? '', 'nftset') >= 0 : null
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

// Subnets of the geoip categories that direct and block sections use: they
// go into nftables sets, so this traffic never reaches xray.
function geo_cidrs(sections, sources) {
	const per_source = {};
	const out = {};

	for (let sec in sections) {
		if (!is_true(sec.enabled ?? '1') || index([ 'exclusion', 'block', 'interface' ], sec.type) < 0)
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
// dnsmasq needs them spelled out. Cached in RAM like the subnets.
function geo_domains(sections, sources) {
	const per_source = {};
	const out = {};
	const used = {};
	const cache_dir = `${RUN_DIR}/geo-cache`;

	for (let sec in sections) {
		if (!is_true(sec.enabled ?? '1') || sec.type != 'interface' || (sec.route_mode ?? 'kernel') == 'xray')
			continue;

		for (let d in entries(sec.domain)) {
			const r = norm_domain(d);

			if (!r.geo || r.geo.attr != '')
				continue;

			const x = resolve(sources, r.geo);

			if (x.state == 'ready') {
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

function load_model() {
	const c = cursor(UCI_DIR);

	c.load('mayhem');

	const sections = [];

	c.foreach('mayhem', 'section', (s) => {
		push(sections, s);
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

	return {
		subscriptions: subscriptions,
		geo: { sources: sources, cidrs: geo_cidrs(sections, sources), domains: geo_domains(sections, sources) },
		lists: lists(sections),
		settings: c.get_all('mayhem', 'settings') ?? {},
		dns: c.get_all('mayhem', 'dns') ?? {},
		sections: sections,
		runtime: runtime(sections)
	};
}

return { load_model, runtime };
