#!/usr/bin/ucode
// Mayhem: downloads geo data and rule lists.
//
//   update.uc due                  what is due: missing data, the nightly geo update,
//                                  lists older than their interval (the scheduler runs this)
//   update.uc geo [NAME] [--force] update geo sources
//   update.uc lists [--force]      update rule lists
//
// A geo file is streamed through the parser as it downloads: only the
// categories that sections use are kept (/etc/mayhem/geo/<source>.dat), plus an
// index of every category with its size for the GUI (<source>.json).
// Files on flash are rewritten only when their content changed.
// Exit code: 0 nothing changed, 3 something changed (the service must reload),
// 1 everything that was tried failed, 4 another update is running.

'use strict';

import * as fs from 'fs';
import { is_true, entries, list_key } from 'mayhem.rules';
import { scan, wanted } from 'mayhem.geo';
import * as C from 'mayhem.const';

const STATE_FILE = `${C.RUN_DIR}/data-state.json`;
const LOCK_DIR = `${C.RUN_DIR}/update.lock`;
const TMP = getenv('MAYHEM_TMP_DIR') ?? '/tmp';
const RETRY_S = 15 * 60;
const NIGHTLY_MIN_AGE_S = 20 * 3600;
const MAX_AGE_S = 48 * 3600;
const LIST_MAX_BYTES = 20 * 1024 * 1024;

function q(s) {
	return "'" + replace(`${s}`, /'/g, "'\\''") + "'";
}

function log(msg, level) {
	system(sprintf('logger -t mayhem -p daemon.%s -- %s', level ?? 'info', q(msg)));
}

function read_json(path) {
	try {
		return json(fs.readfile(path) ?? '');
	}
	catch (e) {
		return null;
	}
}

function write_file(path, data) {
	const tmp = `${path}.tmp`;

	if (fs.writefile(tmp, data) == null || !fs.rename(tmp, path))
		die(`cannot write ${path}: ${fs.error()}`);
}

function write_json(path, v) {
	write_file(path, sprintf('%J\n', v));
}

// Geo files and lists reach tens of megabytes: they are compared and copied
// a piece at a time, never held in RAM whole (twice, for a comparison).
const CHUNK = 65536;

function same_file(a, b) {
	const sa = fs.stat(a), sb = fs.stat(b);

	if (!sa || !sb || sa.size != sb.size)
		return false;

	const fa = fs.open(a, 'r'), fb = fs.open(b, 'r');
	let same = fa != null && fb != null;

	while (same) {
		const x = fa.read(CHUNK), y = fb.read(CHUNK);

		if (x == null || y == null || x != y)
			same = false;
		else if (x == '')
			break;
	}

	if (fa) fa.close();
	if (fb) fb.close();

	return same;
}

// Copies src to dst (through dst.tmp, like write_file).
function copy_file(src, dst) {
	const tmp = `${dst}.tmp`;
	const i = fs.open(src, 'r'), o = fs.open(tmp, 'w');
	let ok = i != null && o != null;

	while (ok) {
		const d = i.read(CHUNK);

		if (d == null)
			ok = false;
		else if (d == '')
			break;
		else if (o.write(d) != length(d))
			ok = false;
	}

	if (i) i.close();
	if (o && !o.close()) ok = false;

	if (!ok || !fs.rename(tmp, dst)) {
		const err = fs.error();

		fs.unlink(tmp);
		die(`cannot write ${dst}: ${err ?? 'write failed'}`);
	}
}

// --- configuration ----------------------------------------------------------------

function load() {
	const c = require('uci').cursor(C.UCI_DIR);

	c.load('mayhem');

	const cfg = { geo: c.get_all('mayhem', 'geo') ?? {}, sources: [], sections: [] };

	c.foreach('mayhem', 'section', (s) => push(cfg.sections, s));
	c.foreach('mayhem', 'geo_source', (s) => {
		const idx = read_json(`${C.GEO_DIR}/${s['.name']}.json`);

		push(cfg.sources, {
			name: s['.name'],
			kind: s.kind == 'geoip' ? 'geoip' : 'geosite',
			enabled: is_true(s.enabled ?? '1'),
			url: s.url ?? '',
			index: type(idx) == 'object' ? idx : null
		});
	});

	return cfg;
}

// The default section: downloads go through its active server, like the
// remote DNS. The generator wrote which one it is.
function route_section(cfg) {
	const st = read_json(`${C.RUN_DIR}/nodes.json`);

	if (st?.default_section)
		return st.default_section;

	return filter(cfg.sections, (s) => (s.type ?? 'proxy') == 'proxy' && is_true(s.enabled ?? '1'))[0]?.['.name'];
}

// Download through Xray: older configs said so with update_via.
function via_xray(o) {
	if (o.via_xray != null && o.via_xray != '')
		return is_true(o.via_xray);

	return (o.update_via ?? 'auto') != 'direct';
}

// Download routes to try, in order: null = direct, else a proxy URL.
// Through Xray first when that is on, direct as the fallback.
function routes(cfg) {
	const sec = route_section(cfg);
	const out = [];

	if (via_xray(cfg.geo) && sec)
		push(out, `socks5h://sec-${sec}:${C.HELPER_PASS}@127.0.0.1:${C.HELPER_PORT}`);

	push(out, null);

	return out;
}

function local_path(url) {
	if (substr(url, 0, 7) == 'file://')
		return substr(url, 7);

	return substr(url, 0, 1) == '/' ? url : null;
}

function curl_cmd(url, proxy, extra) {
	let cmd = `curl -sSfL --max-redirs 5 --connect-timeout 15 ${extra ?? ''}`;

	if (proxy)
		cmd += ` -x ${q(proxy)}`;

	return cmd + ` ${q(url)}`;
}

// --- lock ------------------------------------------------------------------------

function lock() {
	fs.mkdir(C.RUN_DIR, 0700);

	for (let i = 0; i < 2; i++) {
		if (fs.mkdir(LOCK_DIR, 0700)) {
			fs.writefile(`${LOCK_DIR}/pid`, `${fs.readlink('/proc/self')}\n`);
			return true;
		}

		// A lock left by a process that is gone is stale.
		const pid = int(trim(fs.readfile(`${LOCK_DIR}/pid`) ?? '0'));

		if (pid > 0 && fs.access(`/proc/${pid}`))
			return false;

		fs.unlink(`${LOCK_DIR}/pid`);
		fs.rmdir(LOCK_DIR);
	}

	return false;
}

function unlock() {
	fs.unlink(`${LOCK_DIR}/pid`);
	fs.rmdir(LOCK_DIR);
}

// --- geo -------------------------------------------------------------------------

// Streams one source through the parser. Returns { categories, copied, bytes }
// and leaves the trimmed file at `tmp`.
function fetch_geo(src, cats, proxy, tmp) {
	const want = {};

	for (let c in cats)
		want[uc(c)] = true;

	const out = fs.open(tmp, 'w');

	if (!out)
		die(`cannot write ${tmp}: ${fs.error()}`);

	const path = local_path(src.url);
	const err = `${tmp}.err`;
	let fh, res, rc = 0;

	if (path) {
		fh = fs.open(path, 'r');

		if (!fh) {
			out.close();
			die(`cannot read ${path}: ${fs.error()}`);
		}
	}
	else {
		// Up to 15 minutes for ~70 MB on a slow link.
		fh = fs.popen(curl_cmd(src.url, proxy, '-m 900') + ` 2>${q(err)}`, 'r');

		if (!fh) {
			out.close();
			die('cannot run curl');
		}
	}

	try {
		res = scan(fh, want, out);
	}
	catch (e) {
		fh.close();
		out.close();
		die(e.message);
	}

	rc = fh.close();
	out.close();

	if (!path && rc != 0) {
		const msg = trim(fs.readfile(err) ?? '');

		fs.unlink(err);
		die(msg != '' ? msg : `curl exit code ${rc}`);
	}

	fs.unlink(err);

	if (!length(keys(res.categories)))
		die('the file is empty or not a geo file');

	return res;
}

function update_source(cfg, src, cats, state, now) {
	const st = state.geo[src.name] ??= {};
	const tmp = `${TMP}/mayhem-geo-${src.name}.dat`;
	let res = null, last = 'no download route', via = null;

	st.last_try = now;

	for (let proxy in (local_path(src.url) ? [ null ] : routes(cfg))) {
		try {
			res = fetch_geo(src, cats, proxy, tmp);
			via = proxy ? 'xray' : 'direct';
			break;
		}
		catch (e) {
			last = e.message;
		}
	}

	if (!res) {
		fs.unlink(tmp);
		st.error = last;
		log(`geo source ${src.name}: ${last}`, 'warn');
		return { ok: false, error: last };
	}

	const dat = `${C.GEO_DIR}/${src.name}.dat`;
	const changed_dat = !same_file(tmp, dat);

	fs.mkdir(fs.dirname(C.GEO_DIR), 0755);
	fs.mkdir(C.GEO_DIR, 0755);

	try {
		if (changed_dat)
			copy_file(tmp, dat);
	}
	catch (e) {
		fs.unlink(tmp);
		die(e.message);
	}

	fs.unlink(tmp);

	const copied = sort(res.copied);
	const old = src.index;
	const changed_copied = sprintf('%J', copied) != sprintf('%J', sort(old?.copied ?? []));
	const index = { kind: src.kind, url: src.url, size: res.bytes, categories: res.categories, copied: copied, updated: now };

	if (!old || old.url != src.url || old.size != res.bytes || changed_copied ||
	    sprintf('%J', old.categories) != sprintf('%J', res.categories))
		write_json(`${C.GEO_DIR}/${src.name}.json`, index);

	st.last_ok = now;
	st.via = via;
	delete st.error;

	const missing = filter(cats, (c) => res.categories[c] == null);

	if (length(missing))
		log(`geo source ${src.name} has no categories ${join(', ', missing)}`, 'warn');

	if (changed_dat || changed_copied)
		log(`geo source ${src.name} updated: ${join(', ', copied) || 'no categories in use'}`);

	return {
		ok: true, via: via, categories: length(keys(res.categories)), copied: copied,
		missing: missing, changed: changed_dat || changed_copied
	};
}

function geo_due(cfg, src, cats, st, now) {
	const idx = src.index;

	// A source nobody uses is downloaded only on request (the GUI needs it
	// once for the category list): 70 MB every night would be a waste.
	if (!length(cats))
		return null;

	if (!idx || idx.url != src.url)
		return 'never downloaded';

	// Categories a section asked for that are known but not kept yet.
	const missing = filter(cats, (c) => idx.categories?.[c] != null && index(idx.copied ?? [], c) < 0);

	if (length(missing))
		return `new categories ${join(', ', missing)}`;

	const last = max(st.last_ok ?? 0, idx.updated ?? 0);
	const hour = int(cfg.geo.update_hour ?? 4);

	if (now - last >= MAX_AGE_S)
		return 'outdated';

	if (now - last >= NIGHTLY_MIN_AGE_S && localtime(now).hour == hour)
		return 'nightly update';

	return null;
}

function run_geo(cfg, state, name, force) {
	const now = time();
	const want = wanted(cfg.sections, cfg.sources);
	const results = [];

	for (let src in cfg.sources) {
		if (name ? src.name != name : !src.enabled)
			continue;

		const st = state.geo[src.name] ?? {};

		if (!force) {
			const why = geo_due(cfg, src, want[src.name] ?? [], st, now);

			if (!why)
				continue;

			if (st.error && now - (st.last_try ?? 0) < RETRY_S)
				continue;
		}

		if (src.url == '') {
			push(results, { name: src.name, ok: false, error: 'no URL' });
			continue;
		}

		const r = update_source(cfg, src, want[src.name] ?? [], state, now);

		r.name = src.name;
		push(results, r);
		write_json(STATE_FILE, state);
	}

	return results;
}

// --- rule lists ------------------------------------------------------------------

function list_urls(cfg) {
	const out = [];

	for (let s in cfg.sections)
		if (is_true(s.enabled ?? '1'))
			for (let u in entries(s.list_url))
				if (match(u, /^https?:\/\//) && index(out, u) < 0)
					push(out, u);

	return out;
}

function fetch_list(cfg, url) {
	const tmp = `${TMP}/mayhem-list.${list_key(url)}`;
	let last = 'no download route';

	for (let proxy in routes(cfg)) {
		const p = fs.popen(curl_cmd(url, proxy, `-m 120 --max-filesize ${LIST_MAX_BYTES} -o ${q(tmp)}`) + ' 2>&1', 'r');
		const err = p ? trim(p.read('all') ?? '') : 'cannot run curl';
		const rc = p ? p.close() : -1;

		// The caller compares and keeps the file, then removes it. curl does
		// not create it for an empty answer: an empty list.
		if (rc == 0) {
			if (!fs.stat(tmp))
				fs.writefile(tmp, '');

			return { file: tmp, via: proxy ? 'xray' : 'direct' };
		}

		fs.unlink(tmp);
		last = err != '' ? err : `curl exit code ${rc}`;
	}

	die(last);
}

function run_lists(cfg, state, force) {
	const now = time();
	const hours = int(cfg.geo.lists_interval ?? 24) || 24;
	const urls = list_urls(cfg);
	const keep = {};
	const results = [];

	fs.mkdir(fs.dirname(C.LISTS_DIR), 0755);
	fs.mkdir(C.LISTS_DIR, 0755);

	for (let url in urls) {
		const key = list_key(url);
		const path = `${C.LISTS_DIR}/${key}.lst`;
		const st = state.lists[url] ??= {};
		const mtime = fs.stat(path)?.mtime;

		keep[`${key}.lst`] = true;

		if (!force && mtime != null) {
			if (now - max(st.last_ok ?? 0, mtime) < hours * 3600)
				continue;
		}

		if (!force && st.error && now - (st.last_try ?? 0) < RETRY_S)
			continue;

		st.last_try = now;

		try {
			const r = fetch_list(cfg, url);
			const bytes = fs.stat(r.file)?.size ?? 0;
			let changed;

			try {
				changed = !same_file(r.file, path);

				if (changed)
					copy_file(r.file, path);
			}
			catch (e) {
				fs.unlink(r.file);
				die(e.message);
			}

			fs.unlink(r.file);
			st.last_ok = now;
			st.via = r.via;
			delete st.error;
			push(results, { url: url, ok: true, via: r.via, changed: changed, bytes: bytes });
		}
		catch (e) {
			st.error = e.message;
			log(`list ${url}: ${e.message}`, 'warn');
			push(results, { url: url, ok: false, error: e.message });
		}
	}

	// Lists no section uses any more.
	for (let f in fs.lsdir(C.LISTS_DIR) ?? [])
		if (match(f, /\.lst$/) && !keep[f])
			fs.unlink(`${C.LISTS_DIR}/${f}`);

	for (let u in keys(state.lists))
		if (index(urls, u) < 0)
			delete state.lists[u];

	return results;
}

// --- main ------------------------------------------------------------------------

const cmd = ARGV[0];
const force = index(ARGV, '--force') >= 0;
const name = filter(slice(ARGV, 1), (a) => a != '--force')[0];

if (index([ 'due', 'geo', 'lists' ], cmd) < 0) {
	warn('usage: update.uc due | geo [NAME] [--force] | lists [--force]\n');
	exit(2);
}

if (!lock()) {
	print('{ "busy": true }\n');
	exit(4);
}

let results = [], rc = 0;

try {
	const cfg = load();
	const state = read_json(STATE_FILE) ?? {};

	state.geo ??= {};
	state.lists ??= {};

	if (cmd == 'geo' || cmd == 'due')
		results = [ ...results, ...run_geo(cfg, state, name, force) ];

	if (cmd == 'lists' || cmd == 'due')
		results = [ ...results, ...run_lists(cfg, state, force) ];

	write_json(STATE_FILE, state);

	const failed = filter(results, (r) => !r.ok);

	if (length(filter(results, (r) => r.ok && r.changed)))
		rc = 3;
	else if (length(results) && length(failed) == length(results))
		rc = 1;
}
catch (e) {
	unlock();
	warn(`mayhem: ${e.message}\n`);
	exit(1);
}

unlock();
print(sprintf('%J\n', results));
exit(rc);
