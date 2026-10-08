#!/usr/bin/ucode
// Mayhem: puts a new server list into running xray without a restart.
//
//   live.uc
//
// Called on reload after the generator wrote the new config. The servers
// (outbounds n-<section>-<hash> and the fallbacks f-<section>), the helper
// users that reach single servers and the server choices are swapped through
// xray's API; connections that use a server keep going until they end. Only
// when everything else is the same (xray.key equals the key xray started
// with); otherwise procd restarts xray and there is nothing to do here.
//
// Exit code 0: nothing to do, or done. 1: xray did not take the change (the
// caller restarts it).

'use strict';

import * as fs from 'fs';
import { RUN_DIR, API_PORT } from 'mayhem.const';

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
	const rc = system(`${XRAY} api ${cmd} --server=127.0.0.1:${API_PORT} ${args} >${out} 2>&1`);

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

// --- what changed ---------------------------------------------------------------

// Anything but the servers changed: procd restarts xray with the new config.
if (read('xray.key') != read('running.xray.key'))
	exit(0);

const cur = read_json('running.xray.json');
const next = read_json('xray.json');

if (!cur || !next) {
	warn('live: cannot read the configs\n');
	exit(1);
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

const add_rules = map(filter(keys(new_rules), (t) => !old_rules[t] || !same(old_rules[t], new_rules[t])), (t) => new_rules[t]);
const remove_rules = filter(keys(old_rules), (t) => !new_rules[t] || !same(old_rules[t], new_rules[t]));
const helper = helper_inbound(next);
const helper_changed = !same(helper_inbound(cur), helper);
const choices = !same(old_ov, new_ov);

if (!length(add) && !length(remove) && !length(replace_ob) && !length(add_rules) && !length(remove_rules) &&
    !helper_changed && !choices)
	exit(0);

// Two reloads at once: the second waits for the first.
for (let i = 0; !fs.mkdir(LOCK); i++) {
	const st = fs.stat(LOCK);

	if (i >= 30 || (st && time() - st.mtime > 60)) {
		fs.rmdir(LOCK);
		continue;
	}

	sleep(1000);
}

// --- apply ------------------------------------------------------------------------
// New servers first, the old ones go last: there is always a server for every
// tag the routing or a choice names.

if (length(add))
	api_file('ado', { outbounds: add });

// A server under the same tag with other settings (a fallback that follows
// the first server): out and in again.
for (let o in replace_ob) {
	api('rmo', q(o.tag));
	api_file('ado', { outbounds: [ o ] });
}

if (length(remove_rules))
	api('rmrules', join(' ', map(remove_rules, q)));

if (length(add_rules))
	api_file('adrules', { routing: { rules: add_rules } }, '-append');

if (helper_changed) {
	api('rmi', 'helper-in');

	if (helper)
		api_file('adi', { inbounds: [ helper ] });
}

// Server choices by tag: pinned and manual servers may have a new tag now.
for (let bal in keys(new_ov))
	api('bo', `-b ${q(bal)} ${q(new_ov[bal])}`);

for (let bal in keys(old_ov))
	if (!new_ov[bal])
		api('bo', `-b ${q(bal)} -r`);

if (length(remove))
	api('rmo', join(' ', map(remove, q)));

fs.rmdir(LOCK);

if (failed) {
	warn(`live: ${failed}\n`);
	log(`servers could not be changed in running xray: ${failed}`, 'warn');
	exit(1);
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

log(`servers changed without a restart: ${n_add} added, ${length(filter(remove, (t) => match(t, /^n-/)))} removed`);
exit(0);
