#!/usr/bin/ucode
// Mayhem: configuration generator.
//
//   gen.uc [--model FILE] [--out DIR] [--check] [--print] [--warm]
//
// Reads /etc/config/mayhem (or a JSON model with --model), then writes
// xray.json, nft.conf, dnsmasq.conf, env and status.json into DIR
// (/var/run/mayhem by default). --check writes nothing and prints the status.
// Exit code 1 means the configuration has errors and must not be started.
//
// nft.conf and dnsmasq.conf are kept in DIR/net-cache and taken from there
// while what they are made from stays the same: the rules of the sections,
// the settings, geo files, lists, what the router has, Mayhem itself. New
// servers or subscriptions do not change them. One entry per kernel tunnel
// that takes the rest of the traffic (a tunnel of the server list) and one
// without. --warm, run in the background after a start, fills the entries
// of the other choices of the server list, so a switch between a tunnel and
// a proxy finds its files ready; it writes nothing else.

'use strict';

import * as fs from 'fs';
import { build } from 'mayhem.build';
import { RUN_DIR, GEO_DIR } from 'mayhem.const';
import * as runstate from 'mayhem.runstate';

const opts = { out: RUN_DIR, model: null, check: false, print: false, warm: false };

for (let i = 0; i < length(ARGV); i++) {
	switch (ARGV[i]) {
	case '--model': opts.model = ARGV[++i]; break;
	case '--out': opts.out = ARGV[++i]; break;
	case '--check': opts.check = true; break;
	case '--print': opts.print = true; break;
	case '--warm': opts.warm = true; break;
	default:
		warn(`unknown argument "${ARGV[i]}"\n`);
		exit(2);
	}
}

let model;

try {
	if (opts.model)
		model = json(fs.readfile(opts.model) ?? '');
	else
		model = require('mayhem.model').load_model(opts.warm);
}
catch (e) {
	warn(`cannot load configuration: ${e.message}\n`);
	exit(1);
}

const CACHE = `${opts.out}/net-cache`;

// Mayhem itself: an update builds again.
function code_stamp() {
	const here = sourcepath(0, true);
	const out = [];

	for (let d in [ here, `${here}/../ucode/mayhem` ])
		for (let f in sort(fs.lsdir(d) ?? [])) {
			const st = fs.stat(`${d}/${f}`);

			if (st?.type == 'file')
				push(out, `${f} ${st.size} ${st.mtime}`);
		}

	return out;
}

// What nft.conf and dnsmasq.conf are made from, but the servers: the model
// without them, the geo files instead of their subnets and domains. The
// build adds which tunnels work in the kernel.
function net_base(model) {
	const drop = [ 'link', 'outbound_json', 'subscription', 'sub_rules', 'override', 'selected', 'chain', 'select',
		'local_port', 'local_user', 'local_pass' ];
	const sections = map(model.sections ?? [], (s) => {
		const c = { ...s };

		for (let k in drop)
			delete c[k];

		return c;
	});
	const R = { ...model.runtime };

	// Which server a chain uses now: the build adds the tunnel it means.
	delete R.fallback;

	// Devices come and go; only sections limited to some use them.
	if (!length(filter(sections, (s) => s.devices != null)))
		delete R.leases;

	return sprintf('%J', {
		settings: model.settings, dns: model.dns, sections: sections, tunnel_labels: model.tunnel_labels,
		lists: model.lists, runtime: R, code: code_stamp(),
		geo: { sources: model.geo?.sources, files: model.geo?.files }
	});
}

// An entry is one file, replaced as a whole: a build and --warm may write
// the same one at once.
function cache_get(slot) {
	try {
		const e = json(fs.readfile(`${CACHE}/${slot}.json`) ?? 'null');

		return type(e?.nft) == 'string' && type(e?.dnsmasq) == 'string' ? e : null;
	}
	catch (e) {
		return null;
	}
}

function cache_put(net) {
	if (!net || !match(net.slot, /^[A-Za-z0-9_.@-]+$/))
		return;

	const path = `${CACHE}/${net.slot}.json`;
	const tmp = `${path}.${trim(split(fs.readfile('/proc/self/stat') ?? '', ' ')[0] ?? '')}`;

	fs.mkdir(opts.out, 0700);
	fs.mkdir(CACHE, 0700);

	if (fs.writefile(tmp, sprintf('%J', { key: net.key, nft: net.nft, dnsmasq: net.dnsmasq, warnings: net.warnings })) == null ||
	    !fs.rename(tmp, path))
		fs.unlink(tmp);
}

// With --model (the tests) the cache is used only when asked.
if (!opts.model || getenv('MAYHEM_NET_CACHE') == '1')
	model.net_cache = { base: net_base(model), get: cache_get };

// --warm: the other choices of the server list, a tunnel or a proxy for the
// rest of the traffic, built once for the cache. Nothing else is written.
if (opts.warm) {
	const pool = filter(model.sections ?? [], (s) => s['.name'] == 'pool' && s.pool)[0];
	const D = model.dns ?? {};

	if (!pool || model.settings?.mode != 'global' || pool.select == 'fallback' || !length(pool.iface_node ?? []) ||
	    model.runtime?.dnsmasq_nftset === false)
		exit(0);

	// A tunnel by its interface; a proxy as no pinned server at all.
	for (let v in [ ...pool.iface_node, null ]) {
		const p = { ...pool, override: v };

		delete p.selected;

		const r = build({
			...model,
			geo: { ...(model.geo ?? {}), domains: (v == null ? model.geo?.narrow : model.geo?.wide) ?? model.geo?.domains },
			sections: map(model.sections, (s) => s['.name'] == 'pool' ? p : s)
		});

		if (r.ok)
			cache_put(r.net);
	}

	exit(0);
}

const res = build(model);

if (res.ok && !opts.check && !opts.print)
	cache_put(res.net);
const status = {
	ok: res.ok,
	generated: time(),
	mode: res.mode,
	ipv6: res.ipv6,
	memlimit_mib: res.memlimit_mib,
	geo_pending: res.state?.geo_pending,
	lists_missing: res.state?.lists_missing,
	// nft.conf and dnsmasq.conf from the cache, not built
	net_cached: res.net_cached,
	...res.status
};

function put(name, data) {
	const path = `${opts.out}/${name}`;
	const tmp = `${path}.tmp`;

	if (fs.writefile(tmp, data) == null || !fs.rename(tmp, path)) {
		warn(`cannot write ${path}: ${fs.error()}\n`);
		exit(1);
	}
}

if (opts.check) {
	print(sprintf('%.J\n', status));
	exit(res.ok ? 0 : 1);
}

if (opts.print) {
	print(sprintf('%.J\n', res.xray));
	exit(res.ok ? 0 : 1);
}

fs.mkdir(opts.out, 0700);

put('status.json', sprintf('%.J\n', status));

if (!res.ok) {
	for (let e in res.status.errors)
		warn(`mayhem: ${e}\n`);

	exit(1);
}

// Compact: the file lives in RAM (tmpfs), with rule lists it can take
// megabytes; `mayhem show-config` prints it readable.
put('xray.json', sprintf('%J\n', res.xray));
// procd restarts xray when this changes; new servers alone go in live.
put('xray.key', sprintf('%J\n', res.key));
put('nft.conf', res.nft);
put('dnsmasq.conf', res.dnsmasq);
// What dnsmasq asks while xray works (lib.sh, mayhem_dns_servers).
put('dns.xray', res.dns_xray);
// ...and while the remote DNS does not answer (health.uc); empty: no switch.
put('dns.fallback', res.dns_fallback ?? '');
put('env', `GOMEMLIMIT=${res.memlimit_mib}MiB\nGOGC=${res.gogc ?? 100}\nMAYHEM_IPV6=${res.ipv6 ? 1 : 0}\nXRAY_LOCATION_ASSET=${GEO_DIR}\nMAYHEM_KILLSWITCH=${res.killswitch ? 1 : 0}\n`);

// xray reads geo files only at start: procd watches this stamp to restart it
// when a file it uses was updated.
let stamp = '';

for (let f in sort(res.geo_files ?? [])) {
	const st = fs.stat(`${GEO_DIR}/${f}`);

	stamp += `${f} ${st?.size ?? 0} ${st?.mtime ?? 0}\n`;
}

put('geo.stamp', stamp);
// The dashboard and fallback.uc change these two as well (mayhem.runstate).
if (!runstate.write(opts.out, {
	'nodes.json': sprintf('%J\n', res.state),
	'overrides': length(res.overrides) ? join('\n', res.overrides) + '\n' : ''
})) {
	warn(`cannot write ${opts.out}/nodes.json: ${fs.error()}\n`);
	exit(1);
}
put('tunnels', res.tunnels ?? '');
// Subscriptions the service downloads right after this reload.
put('subs.new', length(model.subs_new ?? []) ? join('\n', model.subs_new) + '\n' : '');

for (let w in res.status.warnings)
	warn(`mayhem: warning: ${w}\n`);

exit(0);
