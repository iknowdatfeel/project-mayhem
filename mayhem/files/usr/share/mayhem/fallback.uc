#!/usr/bin/ucode
// Mayhem: moves fallback chains along (sections with select 'fallback').
//
//   fallback.uc
//
// A chain is "server 1, while it works; then server 2; then server 3...".
// In the server list an item of the chain may be a whole subscription: the
// fastest of its servers (a unit of several servers, see fallback_chain()
// in build.uc), its own chain, or the server chosen in it by hand.
// Run by the scheduler every 20 s. The server a chain uses now is checked
// through the helper proxy (a GET of the check URL, like a URL test; a
// failed check is asked again at once). When it does not answer, the chain
// moves on to its next server that answers: the next few that
// xray's own checks (the observatory) do not know to be down are checked at
// once, and the first of them in the chain's order that answers takes over. A server
// earlier in the chain takes over again as soon as the observatory sees it
// working - in a check made after the chain left it: until then xray still
// reports what it saw before, and the chain went back and forth between a
// dead server and the next one. When no server of the chain works, the
// fastest working server of the section is used.
//
// The choice goes into xray as a balancer override (no restart), and into
// overrides, running.overrides and nodes.json like a choice made by hand;
// fallback.json keeps it for the generator across reloads.

'use strict';

import * as fs from 'fs';
import { RUN_DIR, API_PORT, DEFAULT_PROBE_URL } from 'mayhem.const';
import * as check from 'mayhem.check';
import * as metrics from 'mayhem.metrics';
import * as runstate from 'mayhem.runstate';

const XRAY = getenv('MAYHEM_XRAY_BIN') ?? '/usr/libexec/mayhem/xray';
// servers of the chain checked at once when it moves on
const TRIES = 4;
// The server in use is checked in FIRST seconds; when it fails, it is asked
// once more together with the next few of the chain, all at once, in AGAIN
// seconds (as in health.uc).
const FIRST = 5, AGAIN = 4;

function q(s) {
	return "'" + replace(`${s}`, /'/g, "'\\''") + "'";
}

const my_pid = fs.readlink('/proc/self') || split(fs.readfile('/proc/self/stat') ?? '', ' ')[0] || '';

function read_json(name) {
	try {
		return json(fs.readfile(`${RUN_DIR}/${name}`) ?? '');
	}
	catch (e) {
		return null;
	}
}

function write(name, data) {
	const tmp = `${RUN_DIR}/${name}.${my_pid}.tmp`;

	if (fs.writefile(tmp, data) != null)
		fs.rename(tmp, `${RUN_DIR}/${name}`);
}

function command(cmd) {
	const p = fs.popen(cmd, 'r');

	if (!p)
		return '';

	const out = p.read('all') ?? '';

	p.close();

	return out;
}

function log(msg, level) {
	system(`logger -t mayhem -p daemon.${level ?? 'info'} -- ${q(msg)}`);
}

function is_applying() {
	const now = time();

	for (let f in fs.glob(`${RUN_DIR}/applying.*`) ?? []) {
		const st = fs.stat(f);

		if (!st)
			continue;

		const m = match(f, /applying\.([0-9]+)$/);
		if (m) {
			const apid = m[1];
			if (!fs.stat(`/proc/${apid}`)) {
				fs.unlink(f);
				continue;
			}
		}

		if (now - st.mtime < 300)
			return true;

		fs.unlink(f);
	}

	return false;
}

if (is_applying())
	exit(0);

const state = read_json('nodes.json');
const chains = filter(keys(state?.sections ?? {}), (sn) => state.sections[sn].mode == 'fallback' && length(state.sections[sn].chain ?? []));

if (!length(chains) || !fs.access(`${RUN_DIR}/active`))
	exit(0);

const LOCK = `${RUN_DIR}/fallback.lock`;

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
		fs.writefile(`${LOCK}/pid`, `${my_pid}\n`);
		break;
	}

	const lock_pid = int(trim(fs.readfile(`${LOCK}/pid`) ?? '0'));
	const st = fs.stat(LOCK);

	if ((lock_pid > 0 && !fs.access(`/proc/${lock_pid}`)) || (lock_pid <= 0 && st && time() - st.mtime > 60)) {
		unlock();
		continue;
	}

	if (i >= 30)
		exit(0);

	sleep(500);
}

const started = time();

// What xray's own checks saw (2 s at most: a hung xray must not hold the
// scheduler).
const obs = metrics.observatory(2000);

// true / false when the observatory checked the server, null before that
const alive = (t) => obs[t] ? obs[t].alive == true : null;
const url = match(state.probe_url ?? '', /^https?:\/\//) ? state.probe_url : DEFAULT_PROBE_URL;

const now = read_json('fallback.json') ?? {};
// section -> { tag: xray's number of checks of it when the chain left it }
const left = read_json('fallback.left') ?? {};
const checks = (t) => obs[t]?.health_ping?.all ?? 0;
const moved = {};
// section -> the server it moved to
const chosen = {};

for (let sn in chains) {
	const s = state.sections[sn];
	const tags = map(s.nodes ?? [], (n) => n.tag);
	const name = (t) => filter(s.nodes, (n) => n.tag == t)[0]?.name ?? t;
	// Units, tried in order: one server, or "the fastest of these" (a
	// subscription in the server list's chain), fastest first.
	const delay = (t) => obs[t]?.delay ?? 1e9;
	const units = filter(map(s.units ?? map(s.chain, (t) => [ t ]), (u) =>
		sort(filter(u, (t) => index(tags, t) >= 0), (a, b) => (alive(b) === true) - (alive(a) === true) || delay(a) - delay(b))),
		(u) => length(u));
	const chain = [];

	for (let u in units)
		for (let t in u)
			push(chain, t);

	if (!length(chain))
		continue;

	// xray has checked the server since the chain left it: its word counts
	// again.
	left[sn] ??= {};

	for (let t in keys(left[sn]))
		if (index(tags, t) < 0 || checks(t) > left[sn][t])
			delete left[sn][t];

	const back = (t) => alive(t) === true && left[sn][t] == null;

	const unit_of = (t) => {
		for (let i = 0; i < length(units); i++)
			if (index(units[i], t) >= 0)
				return i;

		return -1;
	};

	let cur = now[sn] ?? s.selected;

	if (index(chain, cur) < 0)
		cur = chain[0];

	let want = null;

	// A unit earlier in the chain works again: its fastest working server.
	for (let i = 0; i < unit_of(cur); i++) {
		want = filter(units[i], back)[0];

		if (want)
			break;
	}

	// Within "the fastest of these": a working server clearly faster than
	// the current one (by 30 ms and a fifth) takes over, like xray's own
	// automatic choice; small differences do not move it back and forth.
	const k = unit_of(cur);

	if (!want && length(units[k]) > 1) {
		const best = filter(units[k], back)[0];

		if (best && best != cur && (alive(cur) !== true || delay(best) + max(30, delay(cur) / 5) < delay(cur)))
			want = best;
	}

	if (!want && check.works_many([ cur ], url, FIRST)[cur] != null)
		want = cur;

	if (!want) {
		// The rest of the current unit first (fastest first), then the
		// units after it, then those before it.
		const rest = [ ...filter(units[k], (t) => t != cur) ];

		for (let i = k + 1; i < length(units); i++)
			push(rest, ...units[i]);

		for (let i = 0; i < k; i++)
			push(rest, ...units[i]);

		// The next few xray does not know to be down, checked at once with
		// the current one again: the current one if it answers now (a lost
		// packet does not move the chain), else the first of them in the
		// chain that answers.
		const next = slice(filter(rest, (t) => alive(t) !== false && left[sn][t] == null), 0, TRIES);
		const ms = check.works_many([ cur, ...next ], url, AGAIN);

		if (ms[cur] != null)
			want = cur;
		else if (length(next)) {
			want = filter(next, (t) => ms[t] != null)[0];

			// None of them answered either: they count as left, so the next
			// run tries the next few, and the chain stays where it is
			// meanwhile - it moved on to a server that had not answered
			// either, one by one. When nothing answers, health.uc sends the
			// section direct (or the kill switch holds it).
			if (!want) {
				for (let t in next)
					left[sn][t] = checks(t);

				want = cur;
			}
		}
		// The whole chain was tried: the fastest server of the section xray
		// sees working, if any.
		else {
			const ok = sort(filter(tags, (t) => alive(t) === true && t != cur), (a, b) => (obs[a].delay ?? 0) - (obs[b].delay ?? 0));

			want = ok[0] ?? cur;
		}

		if (want != cur)
			left[sn][cur] = checks(cur);
	}

	now[sn] = want;

	if (want == s.selected)
		continue;

	if (is_applying()) {
		now[sn] = s.selected;
		continue;
	}

	const cur_h = read_json('health.json');
	if ((cur_h?.sections?.[sn]?.picked ?? 0) >= started) {
		now[sn] = s.selected;
		continue;
	}

	const rc = system(`${XRAY} api bo --server=127.0.0.1:${API_PORT} -b ${q(s.balancer)} ${q(want)} >/dev/null 2>&1`);

	if (rc != 0) {
		log(`fallback chain of ${sn}: xray did not take ${name(want)}`, 'warn');
		now[sn] = s.selected;
		continue;
	}

	log(unit_of(want) >= 0 && unit_of(want) < unit_of(s.selected)
		? `fallback chain of ${sn}: ${name(want)} works again, back to it`
		: `fallback chain of ${sn}: ${name(s.selected)} does not work, now ${name(want)}`);
	s.selected = want;
	moved[s.balancer] = want;
	chosen[sn] = want;
}

write('fallback.json', sprintf('%J\n', now));
write('fallback.left', sprintf('%J\n', left));

if (length(moved)) {
	// The file as it is now: a reload may have written it meanwhile.
	runstate.update(RUN_DIR, (st) => {
		for (let sn, tag in chosen) {
			const s = st.sections?.[sn];

			if (s && index(map(s.nodes ?? [], (n) => n.tag), tag) >= 0)
				s.selected = tag;
		}
	});

	// The choice for the next start of xray, like a choice made by hand.
	runstate.set_overrides(RUN_DIR, moved);
}

finish(0);
