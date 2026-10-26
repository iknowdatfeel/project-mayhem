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
// through the helper proxy (a GET of the check URL, like a URL test); after
// two failed checks in a row the chain moves on to its next server that
// xray's own checks (the observatory) do not know to be down. A server
// earlier in the chain takes over again as soon as the observatory sees it
// working. When no server of the chain works, the fastest working server of
// the section is used.
//
// The choice goes into xray as a balancer override (no restart), and into
// overrides, running.overrides and nodes.json like a choice made by hand;
// fallback.json keeps it for the generator across reloads.

'use strict';

import * as fs from 'fs';
import { RUN_DIR, API_PORT, METRICS_PORT, HELPER_PORT, HELPER_PASS, DEFAULT_PROBE_URL } from 'mayhem.const';

const XRAY = getenv('MAYHEM_XRAY_BIN') ?? '/usr/libexec/mayhem/xray';
const FAILS = 2;

function q(s) {
	return "'" + replace(`${s}`, /'/g, "'\\''") + "'";
}

function read_json(name) {
	try {
		return json(fs.readfile(`${RUN_DIR}/${name}`) ?? '');
	}
	catch (e) {
		return null;
	}
}

function write(name, data) {
	const tmp = `${RUN_DIR}/${name}.tmp`;

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

const state = read_json('nodes.json');
const chains = filter(keys(state?.sections ?? {}), (sn) => state.sections[sn].mode == 'fallback' && length(state.sections[sn].chain ?? []));

if (!length(chains) || !fs.access(`${RUN_DIR}/active`))
	exit(0);

let obs = {};

try {
	obs = json(command(`curl -s -m 3 http://127.0.0.1:${METRICS_PORT}/debug/vars`))?.observatory ?? {};
}
catch (e) {
	obs = {};
}

// true / false when the observatory checked the server, null before that
const alive = (t) => obs[t] ? obs[t].alive == true : null;
const url = match(state.probe_url ?? '', /^https?:\/\//) ? state.probe_url : DEFAULT_PROBE_URL;

function works(tag) {
	const out = trim(command(`curl -s -o /dev/null -m 6 -x ${q(`socks5h://${tag}:${HELPER_PASS}@127.0.0.1:${HELPER_PORT}`)} -w '%{http_code}' ${q(url)}`));
	const code = int(out);

	return code >= 200 && code < 400;
}

const now = read_json('fallback.json') ?? {};
const fails = read_json('fallback.fails') ?? {};
const moved = {};

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
		want = filter(units[i], (t) => alive(t) === true)[0];

		if (want)
			break;
	}

	// Within "the fastest of these": a working server clearly faster than
	// the current one (by 30 ms and a fifth) takes over, like xray's own
	// automatic choice; small differences do not move it back and forth.
	const k = unit_of(cur);

	if (!want && length(units[k]) > 1) {
		const best = filter(units[k], (t) => alive(t) === true)[0];

		if (best && best != cur && (alive(cur) !== true || delay(best) + max(30, delay(cur) / 5) < delay(cur)))
			want = best;
	}

	if (!want) {
		if (works(cur)) {
			fails[sn] = 0;
			want = cur;
		}
		else if ((fails[sn] = (fails[sn] ?? 0) + 1) < FAILS) {
			want = cur;
		}
		else {
			// The rest of the current unit first (fastest first), then the
			// units after it, then those before it.
			const rest = [ ...filter(units[k], (t) => t != cur) ];

			for (let i = k + 1; i < length(units); i++)
				push(rest, ...units[i]);

			for (let i = 0; i < k; i++)
				push(rest, ...units[i]);

			want = filter(rest, (t) => alive(t) !== false)[0];

			// Nothing of the chain works: the fastest server of the section.
			if (!want) {
				const ok = sort(filter(tags, (t) => alive(t) === true && t != cur), (a, b) => (obs[a].delay ?? 0) - (obs[b].delay ?? 0));

				want = ok[0] ?? cur;
			}

			fails[sn] = 0;
		}
	}

	now[sn] = want;

	if (want == s.selected)
		continue;

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
}

write('fallback.json', sprintf('%J\n', now));
write('fallback.fails', sprintf('%J\n', fails));

if (length(moved)) {
	write('nodes.json', sprintf('%J\n', state));

	// The choice for the next start of xray, like a choice made by hand.
	for (let f in [ 'overrides', 'running.overrides' ]) {
		const lines = filter(split(fs.readfile(`${RUN_DIR}/${f}`) ?? '', '\n'),
			(l) => l != '' && !moved[split(l, ' ')[0]]);

		for (let b in keys(moved))
			push(lines, `${b} ${moved[b]}`);

		write(f, join('\n', lines) + '\n');
	}
}

exit(0);
