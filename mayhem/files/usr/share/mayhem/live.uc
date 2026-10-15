#!/usr/bin/ucode
// Mayhem: puts a new server list into running xray without a restart.
//
//   live.uc
//
// Called on reload after the generator wrote the new config. The servers
// (outbounds n-<section>-<hash> and the fallbacks f-<section>), the routing
// (rules and balancers), the helper users that reach single servers and the
// server choices are swapped through xray's API; connections that use a
// server keep going until they end. Only when everything else is the same
// (xray.key equals the key xray started with); otherwise procd restarts xray
// and there is nothing to do here.
//
// Exit code 0: nothing to do, or done. 1: xray did not take the change (the
// caller restarts it).

'use strict';

import * as fs from 'fs';
import { RUN_DIR, API_PORT, GEO_DIR } from 'mayhem.const';

const XRAY = getenv('MAYHEM_XRAY_BIN') ?? '/usr/libexec/mayhem/xray';
const LOCK = `${RUN_DIR}/live.lock`;

function read(name) {
	return fs.readfile(`${RUN_DIR}/${name}`) ?? '';
}

function read_json(name) {
	try {
		return json(read(name));
	}
	catch (e) {
		return null;
	}
}

function log(msg, level) {
	system(`logger -t mayhem -p daemon.${level ?? 'info'} -- '${replace(msg, /'/g, "'\\''")}'`);
}

function q(s) {
	return "'" + replace(`${s}`, /'/g, "'\\''") + "'";
}

let failed = null;

// One xray API call; the first failure stops the rest.
function api(cmd, args) {
	if (failed)
		return false;

	const out = `${RUN_DIR}/live.out`;
	// Rules name geo categories (ext:file:category): xray api reads them too.
	const rc = system(`XRAY_LOCATION_ASSET=${q(GEO_DIR)} ${XRAY} api ${cmd} --server=127.0.0.1:${API_PORT} ${args} >${out} 2>&1`);

	if (rc != 0) {
		failed = `xray api ${cmd}: ${trim(fs.readfile(out) ?? '')}`;
		return false;
	}

	return true;
}

function api_file(cmd, data, flags) {
	const f = `${RUN_DIR}/live.${cmd}.json`;

	fs.writefile(f, sprintf('%J', data));

	const ok = api(cmd, `${flags ?? ''} ${f}`);

	fs.unlink(f);

	return ok;
}

// "balancer tag" lines -> { balancer: tag }
function overrides(text) {
	const out = {};

	for (let line in split(text, '\n')) {
		const m = match(line, /^([^ ]+) ([^ ]+)$/);

		if (m)
			out[m[1]] = m[2];
	}

	return out;
}

function servers(cfg) {
	const out = {};

	for (let o in cfg?.outbounds ?? [])
		if (match(o.tag ?? '', /^[nf]-/))
			out[o.tag] = o;

	return out;
}

function helper_rules(cfg) {
	const out = {};

	for (let r in cfg?.routing?.rules ?? [])
		if (match(r.ruleTag ?? '', /^h-/))
			out[r.ruleTag] = r;

	return out;
}

function helper_inbound(cfg) {
	return filter(cfg?.inbounds ?? [], (i) => i.tag == 'helper-in')[0];
}

const same = (a, b) => sprintf('%J', a) == sprintf('%J', b);

// The routing without the rules of single servers (h-): when this changed, the
// whole routing is replaced at once.
function routing_body(cfg) {
	return {
		rules: filter(cfg?.routing?.rules ?? [], (r) => !match(r.ruleTag ?? '', /^h-/)),
		balancers: cfg?.routing?.balancers ?? []
	};
}

// --- what changed ---------------------------------------------------------------

// Two reloads at once: the second waits for the first, and only then reads
// what runs (the first one changes it). The lock names its process: one left
// by a process that is gone is taken over, a live one is waited for (a
// reload with 200 servers on a slow router takes a while).
function unlock() {
	fs.unlink(`${LOCK}/pid`);
	fs.rmdir(LOCK);
}

function finish(code) {
	unlock();
	exit(code);
}

for (let i = 0; ; i++) {
	if (fs.mkdir(LOCK)) {
		fs.writefile(`${LOCK}/pid`, `${fs.readlink('/proc/self')}\n`);
		break;
	}

	const pid = int(trim(fs.readfile(`${LOCK}/pid`) ?? '0'));
	const st = fs.stat(LOCK);

	// Gone, or (an old lock without a pid) older than a minute.
	if ((pid > 0 && !fs.access(`/proc/${pid}`)) || (pid <= 0 && st && time() - st.mtime > 60)) {
		unlock();
		continue;
	}

	if (i >= 300) {
		warn('live: another reload still runs after 5 minutes\n');
		exit(1);
	}

	sleep(1000);
}

// Anything but the servers changed: procd restarts xray with the new config.
if (read('xray.key') != read('running.xray.key'))
	finish(0);

const cur = read_json('running.xray.json');
const next = read_json('xray.json');

if (!cur || !next) {
	warn('live: cannot read the configs\n');
	finish(1);
}

const old_ob = servers(cur), new_ob = servers(next);
const old_rules = helper_rules(cur), new_rules = helper_rules(next);
const old_ov = overrides(read('running.overrides')), new_ov = overrides(read('overrides'));

const add = [], remove = [], replace_ob = [];

for (let t in keys(new_ob))
	if (!old_ob[t])
		push(add, new_ob[t]);
	else if (!same(old_ob[t], new_ob[t]))
		push(replace_ob, new_ob[t]);

for (let t in keys(old_ob))
	if (!new_ob[t])
		push(remove, t);

const routing_changed = !same(routing_body(cur), routing_body(next));
const add_rules = map(filter(keys(new_rules), (t) => !old_rules[t] || !same(old_rules[t], new_rules[t])), (t) => new_rules[t]);
const remove_rules = filter(keys(old_rules), (t) => !new_rules[t] || !same(old_rules[t], new_rules[t]));
const helper = helper_inbound(next);
const helper_changed = !same(helper_inbound(cur), helper);
const choices = !same(old_ov, new_ov);

if (!length(add) && !length(remove) && !length(replace_ob) && !length(add_rules) && !length(remove_rules) &&
    !helper_changed && !choices && !routing_changed)
	finish(0);

// --- apply ------------------------------------------------------------------------
// New servers first, the old ones go last: there is always a server for every
// tag the routing or a choice names.

// A server under the same tag with other settings (a fallback that follows
// the first server) goes out first and in again with the new ones: one call
// each (every call is an xray process of its own, ~30 MB for a moment).
if (length(replace_ob))
	api('rmo', join(' ', map(replace_ob, (o) => q(o.tag))));

if (length(add) || length(replace_ob))
	api_file('ado', { outbounds: [ ...add, ...replace_ob ] });

// Other rules or balancers (the main section, a fallback chain, rules of a
// section): the routing is replaced as a whole; balancers start over, so
// every choice goes in again below.
if (routing_changed)
	api_file('adrules', { routing: { rules: next.routing?.rules ?? [], balancers: next.routing?.balancers ?? [] } });
else {
	if (length(remove_rules))
		api('rmrules', join(' ', map(remove_rules, q)));

	if (length(add_rules))
		api_file('adrules', { routing: { rules: add_rules } }, '-append');
}

if (helper_changed) {
	api('rmi', 'helper-in');

	if (helper)
		api_file('adi', { inbounds: [ helper ] });
}

// Server choices by tag: pinned and manual servers may have a new tag now.
for (let bal in keys(new_ov))
	if (routing_changed || old_ov[bal] != new_ov[bal])
		api('bo', `-b ${q(bal)} ${q(new_ov[bal])}`);

// New balancers forgot that a tunnel is down: the next tunnel check points
// them at "direct" again.
if (routing_changed)
	for (let f in fs.lsdir(RUN_DIR) ?? [])
		if (match(f, /^tunnel\..*\.sel$/))
			fs.unlink(`${RUN_DIR}/${f}`);

for (let bal in keys(old_ov))
	if (!new_ov[bal])
		api('bo', `-b ${q(bal)} -r`);

if (length(remove))
	api('rmo', join(' ', map(remove, q)));


if (failed) {
	warn(`live: ${failed}\n`);
	log(`servers could not be changed in running xray: ${failed}`, 'warn');
	finish(1);
}

// From now on running xray has the new servers. A hard link where it works:
// the generator replaces these files, so the link keeps this content, and
// the config does not take RAM twice.
for (let f in [ 'xray.json', 'overrides' ]) {
	const tmp = `${RUN_DIR}/running.${f}.tmp`;

	fs.unlink(tmp);

	if (system([ 'ln', '-f', `${RUN_DIR}/${f}`, tmp ]) == 0 || fs.writefile(tmp, read(f)) != null)
		fs.rename(tmp, `${RUN_DIR}/running.${f}`);
}

const n_add = length(filter(add, (o) => match(o.tag, /^n-/)));

if (routing_changed)
	log('routing changed without a restart');

if (length(add) || length(remove))
	log(`servers changed without a restart: ${n_add} added, ${length(filter(remove, (t) => match(t, /^n-/)))} removed`);
finish(0);
