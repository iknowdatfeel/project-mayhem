// Mayhem: builds the Xray config, the nftables ruleset and the dnsmasq snippet
// from a configuration model. Pure function: no file or system access, so it
// can be tested off-device. See model.uc for how the model is read from UCI.

'use strict';

import { parse_link, outbound_host, outbound_port, outbound_udp } from 'mayhem.links';
import { is_true, entries, norm_domain, norm_ip, is_ip, dns_server } from 'mayhem.rules';
import * as C from 'mayhem.const';

const LOG_LEVELS = [ 'debug', 'info', 'warning', 'error', 'none' ];

const FAMILY = {
	prefer_ipv4: { dns: 'UseIP', freedom: 'UseIPv4v6', sockopt: 'UseIPv4v6' },
	prefer_ipv6: { dns: 'UseIP', freedom: 'UseIPv6v4', sockopt: 'UseIPv6v4' },
	ipv4_only: { dns: 'UseIPv4', freedom: 'ForceIPv4', sockopt: 'UseIPv4' },
	ipv6_only: { dns: 'UseIPv6', freedom: 'ForceIPv6', sockopt: 'UseIPv6' }
};

const SERVICE_PROTOCOLS = [ 'freedom', 'direct', 'blackhole', 'block', 'dns', 'loopback' ];

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

	if (length(elems))
		s += `\t\telements = { ${join(', ', elems)} }\n`;

	return s + '\t}\n';
}

function build_nft(S, v6, sets) {
	const ifaces = map(length(sets.ifaces) ? sets.ifaces : [ 'br-lan' ], (i) => sprintf('%J', i));
	const mark = sprintf('0x%x', C.FWMARK);
	let s = `table inet ${C.NFT_TABLE}\ndelete table inet ${C.NFT_TABLE}\n\n`;

	s += `table inet ${C.NFT_TABLE} {\n`;
	s += `\tset ifaces {\n\t\ttype ifname\n\t\telements = { ${join(', ', ifaces)} }\n\t}\n`;
	s += nft_set('local4', 'ipv4_addr', C.LOCAL4);
	s += nft_set('local6', 'ipv6_addr', C.LOCAL6);
	s += nft_set('block4', 'ipv4_addr', sets.block4);
	s += nft_set('block6', 'ipv6_addr', sets.block6);
	s += nft_set('direct4', 'ipv4_addr', sets.direct4);
	s += nft_set('direct6', 'ipv6_addr', sets.direct6);
	s += '\n\tchain prerouting {\n';
	s += '\t\ttype filter hook prerouting priority mangle; policy accept;\n';
	s += '\t\tiifname != @ifaces return\n';
	s += '\t\tmeta l4proto != { tcp, udp } return\n';
	s += '\t\tfib daddr type { local, broadcast, multicast } return\n';
	s += '\t\tip daddr @local4 return\n';
	s += '\t\tip6 daddr @local6 return\n';
	s += '\t\tip daddr @block4 counter drop\n';
	s += '\t\tip6 daddr @block6 counter drop\n';
	s += '\t\tip daddr @direct4 counter return\n';
	s += '\t\tip6 daddr @direct6 counter return\n';
	s += `\t\tmeta nfproto ipv4 meta l4proto { tcp, udp } meta mark set meta mark | ${mark} tproxy ip to 127.0.0.1:${C.TPROXY_PORT} counter accept\n`;

	if (v6)
		s += `\t\tmeta nfproto ipv6 meta l4proto { tcp, udp } meta mark set meta mark | ${mark} tproxy ip6 to [::1]:${C.TPROXY_PORT} counter accept\n`;

	s += '\t}\n}\n';

	return s;
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

// All servers of a proxy section: its own links, then nodes of its
// subscriptions that pass the name filters. Returns [{ name, outbound, source }].
function collect_nodes(sec, model, warn) {
	const name = sec['.name'];
	const nodes = [];

	if (sec.proxy_type == 'json') {
		push(nodes, { name: 'JSON', outbound: json_outbound(sec.outbound_json ?? ''), source: 'json' });
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

	// Names identify servers on the dashboard and in saved choices.
	const seen = {};

	for (let nd in nodes) {
		const base = nd.name;
		let k = 1;

		while (seen[nd.name])
			nd.name = `${base} (${++k})`;

		seen[nd.name] = true;
	}

	return nodes;
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

	const outbounds = [
		{ tag: 'direct', protocol: 'freedom', settings: {}, streamSettings: { sockopt: { domainStrategy: F.freedom } } },
		{ tag: 'block', protocol: 'blackhole', settings: {} }
	];

	const nftsets = {
		ifaces: entries(S.interface),
		block4: [], block6: [], direct4: [], direct6: []
	};

	const proxy_domains = [];
	const excl_domains = [];
	const server_hosts = [];
	const block_rules = [];
	const section_rules = [];
	const proxy_targets = {};
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

		const domains = [], ips4 = [], ips6 = [];
		let geo = false;

		for (let d in entries(sec.domain)) {
			const r = norm_domain(d);

			if (r.error)
				warn(`section "${name}": ${r.error}, skipped`);
			else if (r.geo)
				geo = true;
			else
				uniq_push(domains, r.value);
		}

		for (let i in entries(sec.ip)) {
			const r = norm_ip(i);

			if (r.error)
				warn(`section "${name}": ${r.error}, skipped`);
			else if (r.geo)
				geo = true;
			else
				uniq_push(r.family == 4 ? ips4 : ips6, r.cidr);
		}

		if (geo)
			warn(`section "${name}": geosite/geoip rules need geo data, which is not available yet; skipped`);

		let target;

		switch (info.type) {
		case 'proxy':
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
				warn(`section "${name}": no servers (links or subscription nodes), skipped`);
				continue;
			}

			if (length(nodes) > C.MAX_NODES) {
				warn(`section "${name}": ${length(nodes)} servers, only the first ${C.MAX_NODES} are used`);
				nodes = slice(nodes, 0, C.MAX_NODES);
			}

			const smode = sec.select == 'manual' ? 'manual' : 'auto';
			const sinfo = { type: 'proxy', mode: length(nodes) > 1 ? smode : 'single', nodes: [] };

			for (let i = 0; i < length(nodes); i++) {
				const ob = nodes[i].outbound;
				const host = outbound_host(ob);

				ob.tag = `n-${name}-${i}`;
				apply_sockopt(ob, F.sockopt);
				apply_mux(ob, S);
				push(outbounds, ob);
				push(node_tags, ob.tag);

				if (host && !is_ip(host))
					uniq_push(server_hosts, `full:${host}`);

				push(sinfo.nodes, {
					tag: ob.tag,
					name: nodes[i].name,
					protocol: ob.protocol,
					address: host,
					port: outbound_port(ob),
					udp: outbound_udp(ob),
					source: nodes[i].source
				});
			}

			if (length(nodes) == 1) {
				target = { outboundTag: sinfo.nodes[0].tag };
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

				if (smode == 'auto')
					balancer.fallbackTag = (pick ?? sinfo.nodes[0]).tag;

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

			for (let d in domains)
				uniq_push(proxy_domains, d);
			break;

		case 'exclusion':
			target = { outboundTag: 'direct' };
			state.sections[name] = { type: 'exclusion' };

			for (let d in domains)
				uniq_push(excl_domains, d);

			for (let c in ips4)
				uniq_push(nftsets.direct4, c);

			for (let c in ips6)
				uniq_push(nftsets.direct6, c);
			break;

		case 'block':
			target = { outboundTag: 'block' };
			state.sections[name] = { type: 'block' };

			for (let c in ips4)
				uniq_push(nftsets.block4, c);

			for (let c in ips6)
				uniq_push(nftsets.block6, c);
			break;

		case 'interface':
			info.error = 'interface sections are not supported yet';
			warn(`section "${name}": interface sections arrive with AWG support, skipped`);
			continue;

		default:
			info.error = `unknown type "${info.type}"`;
			warn(`section "${name}": unknown type "${info.type}", skipped`);
			continue;
		}

		const list = info.type == 'block' ? block_rules : section_rules;

		if (length(domains))
			push(list, { domain: domains, ...target });

		const ips = [ ...ips4, ...ips6 ];

		if (length(ips))
			push(list, { ip: ips, ...target });

		info.ok = true;
	}

	// --- default route ------------------------------------------------------

	let final_target = { outboundTag: 'direct' };

	if (mode == 'global') {
		const want = S.default_section;

		if (want && proxy_targets[want]) {
			final_target = proxy_targets[want];
		}
		else if (first_proxy) {
			if (want)
				warn(`default section "${want}" is not a working proxy section, using "${first_proxy}"`);

			final_target = proxy_targets[first_proxy];
		}
		else {
			fail('"everything through proxy" mode needs at least one working proxy section');
		}
	}

	// --- DNS ----------------------------------------------------------------

	const domestic = [];
	const remote = [];

	for (let s in entries(D.domestic)) {
		const r = dns_server(s);

		if (r.error)
			warn(`domestic DNS: ${r.error}`);
		else
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

	if (length(server_hosts))
		for (let d in domestic)
			push(servers, ns(d, { domains: server_hosts, skipFallback: true }));

	if (mode == 'lists') {
		if (length(proxy_domains)) {
			if (fakedns)
				push(servers, { address: 'fakedns', domains: proxy_domains, skipFallback: true });

			for (let r in remote)
				push(servers, ns(r, { domains: proxy_domains, skipFallback: true }));
		}

		for (let d in domestic)
			push(servers, ns(d));
	}
	else {
		if (length(excl_domains))
			for (let d in domestic)
				push(servers, ns(d, { domains: excl_domains, skipFallback: true }));

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

	for (let sn in keys(proxy_targets)) {
		push(helper_accounts, { user: `sec-${sn}`, pass: C.HELPER_PASS });
		push(rules, { inboundTag: [ 'helper-in' ], user: [ `sec-${sn}` ], ...proxy_targets[sn] });
	}

	for (let t in node_tags) {
		push(helper_accounts, { user: t, pass: C.HELPER_PASS });
		push(rules, { inboundTag: [ 'helper-in' ], user: [ t ], outboundTag: t });
	}

	if (length(helper_accounts))
		push(rules, { inboundTag: [ 'helper-in' ], outboundTag: 'direct' });

	push(rules, { inboundTag: [ 'dns-in' ], outboundTag: 'dns-out' });

	if (is_true(D.hijack ?? '1'))
		push(rules, { inboundTag: [ 'tproxy-in' ], port: '53', outboundTag: 'dns-out' });

	if (is_true(D.via_proxy)) {
		let dt = proxy_targets[D.proxy_section];

		if (!dt && first_proxy) {
			if (D.proxy_section)
				warn(`DNS section "${D.proxy_section}" is not a working proxy section, using "${first_proxy}"`);

			dt = (mode == 'global') ? final_target : proxy_targets[first_proxy];
		}

		if (dt) {
			const ips = [], doms = [];

			for (let r in remote)
				if (is_ip(r.host))
					uniq_push(ips, r.host);
				else
					uniq_push(doms, `full:${r.host}`);

			if (length(ips))
				push(rules, { inboundTag: [ 'dns-module' ], ip: ips, ...dt });

			if (length(doms))
				push(rules, { inboundTag: [ 'dns-module' ], domain: doms, ...dt });
		}
		else {
			warn('"DNS through proxy" is on, but there is no working proxy section');
		}
	}

	push(rules, { inboundTag: [ 'dns-module' ], outboundTag: 'direct' });

	for (let r in block_rules)
		push(rules, r);

	for (let r in section_rules)
		push(rules, r);

	push(rules, { network: 'tcp,udp', ...final_target });

	// --- assemble -----------------------------------------------------------

	const sniff = [ 'http', 'tls', 'quic' ];

	if (fakedns)
		unshift(sniff, 'fakedns');

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
				settings: { address: plain.address, port: 53, network: 'tcp,udp' }
			}
		],
		outbounds: outbounds,
		routing: { domainStrategy: 'AsIs', rules: rules, balancers: balancers },
		api: { tag: 'api', listen: `127.0.0.1:${C.API_PORT}`, services: [ 'RoutingService' ] },
		metrics: { tag: 'metrics', listen: `127.0.0.1:${C.METRICS_PORT}` },
		stats: {},
		policy: { system: { statsOutboundUplink: true, statsOutboundDownlink: true } }
	};

	if (length(helper_accounts))
		push(xray.inbounds, {
			tag: 'helper-in',
			listen: '127.0.0.1',
			port: C.HELPER_PORT,
			protocol: 'socks',
			settings: { auth: 'password', accounts: helper_accounts, udp: false }
		});

	if (length(observe)) {
		const iv = match(S.probe_interval ?? '', /^[0-9]+[smh]$/) ? S.probe_interval : C.DEFAULT_PROBE_INTERVAL;
		const url = match(S.probe_url ?? '', /^https?:\/\//) ? S.probe_url : C.DEFAULT_PROBE_URL;

		xray.observatory = { subjectSelector: observe, probeURL: url, probeInterval: iv, enableConcurrency: true };
	}

	if (fakedns)
		xray.fakedns = [ { ipPool: C.FAKEDNS_POOL, poolSize: C.FAKEDNS_POOL_SIZE } ];

	state.generated = R.now ?? time();
	state.mode = mode;
	state.probe_url = xray.observatory?.probeURL ?? (match(S.probe_url ?? '', /^https?:\/\//) ? S.probe_url : C.DEFAULT_PROBE_URL);

	return {
		ok: !length(st.errors),
		mode: mode,
		xray: xray,
		nft: build_nft(S, v6, nftsets),
		dnsmasq: `server=127.0.0.1#${C.DNS_PORT}\nno-resolv\n`,
		memlimit_mib: memlimit_mib(S, R),
		ipv6: v6,
		state: state,
		overrides: overrides,
		status: st
	};
}
