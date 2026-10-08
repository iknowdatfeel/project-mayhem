#!/usr/bin/ucode
// Mayhem: subscription downloader.
//
//   sub.uc update [NAME] [--force]     download due (or all with --force) subscriptions
//   sub.uc parse BODY [HEADERS]        parse a saved response, print the result (tests)
//
// Requests look like the Happ client: User-Agent plus x-hwid, x-device-os,
// x-ver-os, x-device-model and x-device-locale. Results are cached in
// /etc/mayhem/subs/<name>.json; failures keep the previous servers.
// Exit code: 0 nothing changed, 3 servers changed (the service must reload),
// 1 every requested subscription failed.

'use strict';

import * as fs from 'fs';
import { parse_link, b64 } from 'mayhem.links';
import { is_true, entries } from 'mayhem.rules';
import * as C from 'mayhem.const';

const SERVICE_PROTOCOLS = [ 'freedom', 'direct', 'blackhole', 'block', 'dns', 'loopback' ];
const DEFAULT_INTERVAL_H = 12;
const RETRY_S = 15 * 60;
const STATE_FILE = `${C.RUN_DIR}/subs-state.json`;

function q(s) {
	return "'" + replace(`${s}`, /'/g, "'\\''") + "'";
}

function nonempty(v) {
	return v != null && v != '';
}

function maybe_b64(v) {
	if (!nonempty(v))
		return v;

	if (substr(v, 0, 7) == 'base64:')
		return b64(substr(v, 7)) ?? v;

	return v;
}

// --- response parsing --------------------------------------------------------------

function parse_headers(raw) {
	// With redirects curl writes every response; keep the last one.
	const blocks = filter(split(replace(raw ?? '', '\r', ''), '\n\n'), (b) => match(b, /^HTTP\//));
	const last = blocks[length(blocks) - 1] ?? '';
	const h = {};
	const lines = split(last, '\n');
	const sm = match(lines[0] ?? '', /^HTTP\/[0-9.]+ ([0-9]+)/);

	h[':status'] = sm ? int(sm[1]) : 0;

	for (let i = 1; i < length(lines); i++) {
		const m = match(lines[i], /^([^:]+):[[:space:]]*(.*)$/);

		if (m)
			h[lc(trim(m[1]))] = trim(m[2]);
	}

	return h;
}

function parse_userinfo(v) {
	if (!nonempty(v))
		return null;

	const r = {};

	for (let part in split(v, ';')) {
		const m = match(trim(part), /^(upload|download|total|expire)=([0-9]+)/);

		if (m)
			r[m[1]] = int(m[2]);
	}

	return length(keys(r)) ? r : null;
}

function parse_info(h) {
	const info = {};
	const title = maybe_b64(h['profile-title']);
	const iv = h['profile-update-interval'];

	if (nonempty(title))
		info.title = title;

	info.userinfo = parse_userinfo(h['subscription-userinfo']);

	if (nonempty(iv) && match(iv, /^[0-9]+$/) && int(iv) > 0)
		info.interval = int(iv);

	if (nonempty(h['support-url']))
		info.support_url = h['support-url'];

	if (nonempty(h['profile-web-page-url']))
		info.web_page = h['profile-web-page-url'];

	if (nonempty(h['announce']))
		info.announce = maybe_b64(h['announce']);

	info.hwid = {
		active: h['x-hwid-active'] == 'true',
		limit: h['x-hwid-limit'] == 'true',
		not_supported: h['x-hwid-not-supported'] == 'true'
	};

	return info;
}

function pick_outbound(cfg) {
	const obs = filter(cfg?.outbounds ?? [], (o) => type(o) == 'object' && index(SERVICE_PROTOCOLS, o.protocol) < 0);

	return filter(obs, (o) => o.tag == 'proxy')[0] ?? obs[0];
}

function link_lines(text) {
	return filter(map(split(replace(text, '\r', ''), '\n'), (l) => trim(l)),
		(l) => match(l, /^[a-z][a-z0-9+.-]*:\/\/[^[:space:]]/i));
}

// Body -> { nodes: [{ name, link } | { name, outbound }], skipped }
function parse_body(body, format) {
	body = trim(body ?? '');

	const res = { nodes: [], skipped: 0, format: null };

	if (format != 'uri') {
		let j = null;

		try {
			j = json(body);
		}
		catch (e) {
			if (format == 'xray_json')
				die('the response is not JSON');
		}

		if (type(j) == 'object' || type(j) == 'array') {
			const configs = type(j) == 'array' ? j : [ j ];
			let n = 0;

			// JSON without outbounds is an error page of the server, not a config.
			if (!length(filter(configs, (c) => type(c?.outbounds) == 'array')))
				die(type(j) == 'object' && type(j.message) == 'string'
					? `the server answered: ${substr(j.message, 0, 200)}`
					: 'the response is JSON, but not an Xray config');

			res.format = 'xray_json';

			for (let cfg in configs) {
				n++;

				const ob = pick_outbound(cfg);

				if (!ob) {
					res.skipped++;
					continue;
				}

				if (ob.streamSettings?.sockopt?.dialerProxy || ob.proxySettings) {
					// Chains of outbounds are not supported yet.
					res.skipped++;
					continue;
				}

				delete ob.tag;
				push(res.nodes, { name: cfg.remarks ?? cfg.name ?? `server ${n}`, outbound: ob });
			}

			return res;
		}
	}

	if (length(filter(split(body, '\n'), (l) => match(l, /^(proxies|port|mixed-port):/))))
		die('Clash/mihomo YAML is not supported, ask for a plain or Xray JSON subscription');

	// A list of keys, plain or in base64. Only lines that start with a scheme
	// count: comments and other text around the keys are not servers.
	let lines = link_lines(body);

	if (!length(lines))
		lines = link_lines(b64(body) ?? '');

	if (!length(lines)) {
		if (match(body, /^(<!doctype|<html|<\?xml|<head|<body)/i))
			die('the address returns a web page, not a subscription: use a direct link to the file');

		die('the response has no server links');
	}

	res.format = 'uri';

	for (let line in lines) {
		try {
			const r = parse_link(line);

			push(res.nodes, { name: r.name != '' ? r.name : `server ${length(res.nodes) + 1}`, link: line });
		}
		catch (e) {
			res.skipped++;
		}
	}

	return res;
}

// --- downloading ------------------------------------------------------------------

function read_json(path) {
	try {
		return json(fs.readfile(path) ?? '');
	}
	catch (e) {
		return null;
	}
}

function write_json(path, v) {
	const tmp = `${path}.tmp`;

	return fs.writefile(tmp, sprintf('%J\n', v)) != null && fs.rename(tmp, path);
}

function request_headers(sub, dev) {
	const pick = (k, def) => nonempty(sub[k]) ? sub[k] : (nonempty(dev[k]) ? dev[k] : def);
	const h = [];

	if (is_true(sub.send_hwid ?? '1')) {
		const hwid = pick('hwid', null);

		if (hwid) push(h, `x-hwid: ${hwid}`);
		push(h, `x-device-os: ${pick('os', 'Android')}`);
		push(h, `x-ver-os: ${pick('os_version', '14')}`);
		push(h, `x-device-model: ${pick('model', 'OpenWrt')}`);
		push(h, `x-device-locale: ${pick('locale', 'ru')}`);
	}

	for (let line in sub.header ?? [])
		if (match(line, /^[A-Za-z0-9-]+:/))
			push(h, line);

	return { ua: pick('user_agent', 'Happ/3.13.0'), headers: h };
}

function curl(url, req, proxy) {
	const tmp = `/tmp/mayhem-sub.${clock()[1]}`;
	let cmd = `curl -sS -L --max-redirs 5 --connect-timeout 10 -m 40 -A ${q(req.ua)}`;

	for (let h in req.headers)
		cmd += ` -H ${q(h)}`;

	if (proxy)
		cmd += ` -x ${q(proxy)}`;

	cmd += ` -D ${q(tmp + '.h')} -o ${q(tmp + '.b')} ${q(url)} 2>&1`;

	const p = fs.popen(cmd, 'r');
	const err = p ? trim(p.read('all') ?? '') : 'cannot run curl';
	const rc = p ? p.close() : -1;

	const res = {
		rc: rc,
		error: err,
		headers: parse_headers(fs.readfile(`${tmp}.h`) ?? ''),
		body: fs.readfile(`${tmp}.b`) ?? ''
	};

	fs.unlink(`${tmp}.h`);
	fs.unlink(`${tmp}.b`);

	return res;
}

// A link to a file page on GitHub or GitLab gives HTML: take the raw file.
function raw_url(url) {
	let m = match(url, /^https:\/\/github\.com\/([^\/]+)\/([^\/]+)\/(blob|raw)\/(.+)$/);

	if (m)
		return `https://raw.githubusercontent.com/${m[1]}/${m[2]}/${m[4]}`;

	m = match(url, /^(https:\/\/gitlab\.[^\/]+\/.+)\/-\/blob\/(.+)$/);

	if (m)
		return `${m[1]}/-/raw/${m[2]}`;

	return url;
}

// Download through Xray (the active server of the default section) when that
// is on, direct as the fallback. Older configs said so with update_via.
function via_xray(sub) {
	if (nonempty(sub.via_xray))
		return is_true(sub.via_xray);

	return (sub.update_via ?? 'auto') != 'direct';
}

function fetch(sub, dev, route_section) {
	const req = request_headers(sub, dev);
	const proxy = (sec) => `socks5h://${sec}:${C.HELPER_PASS}@127.0.0.1:${C.HELPER_PORT}`;
	const url = raw_url(sub.url);
	const tries = [];

	if (via_xray(sub) && route_section)
		push(tries, proxy(`sec-${route_section}`));

	push(tries, null);

	let last = 'download failed';

	for (let pr in tries) {
		const r = curl(url, req, pr);
		const status = r.headers[':status'];

		if (r.rc == 0 && status >= 200 && status < 300)
			return { headers: r.headers, body: r.body, via: pr ? 'xray' : 'direct' };

		last = r.rc != 0 ? (r.error != '' ? r.error : `curl exit code ${r.rc}`) : `HTTP ${status}`;

		if (status == 403 || status == 404 || status == 410)
			break; // the server answered: retrying elsewhere will not help
	}

	die(last);
}

function load_uci() {
	const uci = require('uci').cursor(C.UCI_DIR);

	uci.load('mayhem');

	const subs = [];
	const sections = [];

	uci.foreach('mayhem', 'subscription', (s) => push(subs, s));
	uci.foreach('mayhem', 'section', (s) => push(sections, s));

	return { device: uci.get_all('mayhem', 'device') ?? {}, subs: subs, sections: sections };
}

// The default section: downloads go through its active server, like the
// remote DNS. The generator wrote which one it is.
function route_section(sub, sections) {
	const st = read_json(`${C.RUN_DIR}/nodes.json`);

	if (st?.default_section)
		return st.default_section;

	return filter(sections, (s) => (s.type ?? 'proxy') == 'proxy' && is_true(s.enabled ?? '1'))[0]?.['.name'];
}

function update(name, force) {
	const cfg = load_uci();
	const state = read_json(STATE_FILE) ?? {};
	const now = time();
	const results = [];
	let changed = false, failed = 0, tried = 0;

	fs.mkdir(fs.dirname(C.SUBS_DIR), 0755);
	fs.mkdir(C.SUBS_DIR, 0700);
	fs.mkdir(C.RUN_DIR, 0700);

	for (let sub in cfg.subs) {
		const sn = sub['.name'];

		if (name && name != sn)
			continue;

		if (!name && !is_true(sub.enabled ?? '1'))
			continue;

		if (!nonempty(sub.url)) {
			push(results, { name: sn, ok: false, error: 'no URL' });
			continue;
		}

		const path = `${C.SUBS_DIR}/${sn}.json`;
		const cache = read_json(path);
		const st = state[sn] ?? {};

		if (!force) {
			const hours = int(sub.update_interval ?? 0) || DEFAULT_INTERVAL_H;
			const last = max(cache?.updated ?? 0, st.updated ?? 0);

			if (cache?.url == sub.url && now - last < hours * 3600)
				continue;

			if (st.error && now - (st.last_try ?? 0) < RETRY_S)
				continue;
		}

		tried++;
		st.last_try = now;

		try {
			const r = fetch(sub, cfg.device, route_section(sub, cfg.sections));
			const parsed = parse_body(r.body, 'auto');

			if (!length(parsed.nodes))
				die(parsed.skipped ? `none of ${parsed.skipped} servers could be read` : 'the subscription is empty');

			const fresh = {
				name: sn,
				url: sub.url,
				updated: now,
				format: parsed.format,
				skipped: parsed.skipped,
				info: parse_info(r.headers),
				nodes: parsed.nodes
			};

			const was = cache ? sprintf('%J', cache.nodes) : null;

			if (was != sprintf('%J', fresh.nodes))
				changed = true;

			// The cache lives on flash: rewrite it only when the servers changed.
			// Traffic counters and the time of the last check change every time,
			// so they are kept in RAM (the cache keeps the ones from its last write).
			const same = cache && sprintf('%J', [ cache.url, cache.format, cache.skipped, cache.nodes ]) ==
				sprintf('%J', [ fresh.url, fresh.format, fresh.skipped, fresh.nodes ]);

			if (!same && !write_json(path, fresh))
				die(`cannot save ${path}: ${fs.error()}`);

			st.updated = now;
			st.info = fresh.info;
			delete st.error;
			st.via = r.via;
			push(results, {
				name: sn, ok: true, nodes: length(fresh.nodes), skipped: parsed.skipped, via: r.via,
				hwid_limit: fresh.info.hwid.limit
			});
		}
		catch (e) {
			failed++;
			st.error = e.message;
			push(results, { name: sn, ok: false, error: e.message, cached: length(cache?.nodes ?? []) });
		}

		state[sn] = st;
	}

	write_json(STATE_FILE, state);
	print(sprintf('%J\n', results));

	if (changed)
		return 3;

	return (tried && failed == tried) ? 1 : 0;
}

// --- main -------------------------------------------------------------------------

switch (ARGV[0]) {
case 'update':
	const force = index(ARGV, '--force') >= 0;
	const name = filter(slice(ARGV, 1), (a) => a != '--force')[0];

	exit(update(name, force));

case 'parse':
	try {
		const res = parse_body(fs.readfile(ARGV[1]) ?? '', ARGV[3] ?? 'auto');

		if (ARGV[2])
			res.info = parse_info(parse_headers(fs.readfile(ARGV[2]) ?? ''));

		print(sprintf('%J\n', res));
		exit(0);
	}
	catch (e) {
		print(sprintf('%J\n', { error: e.message }));
		exit(1);
	}

default:
	warn('usage: sub.uc update [NAME] [--force] | sub.uc parse BODY [HEADERS] [FORMAT]\n');
	exit(2);
}
