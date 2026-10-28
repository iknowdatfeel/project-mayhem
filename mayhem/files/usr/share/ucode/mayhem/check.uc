// Mayhem: is a server (or a section's path) working right now?
//
// A GET of the check URL through xray's helper proxy, as user <server tag>
// or sec-<section>: the same request xray's own checks and the URL test make.
// Any HTTP answer counts: it came back through the server, and a site that
// refuses VPN addresses (403, 429) or redirects says nothing about the
// server. health.uc and fallback.uc decide with these checks which server
// carries the traffic.

'use strict';

import * as fs from 'fs';
import { HELPER_PORT, HELPER_PASS, RUN_DIR } from 'mayhem.const';

function q(s) {
	return "'" + replace(`${s}`, /'/g, "'\\''") + "'";
}

function command(cmd) {
	const p = fs.popen(cmd, 'r');

	if (!p)
		return '';

	const out = p.read('all') ?? '';

	p.close();

	return out;
}

// fallback.uc and health.uc run one after the other every 20 s and both
// check the server a section uses: within one run of the scheduler
// (MAYHEM_TICK) a server that answered is not asked again. Only answers are
// kept: a failure is always checked anew.
const TICK = getenv('MAYHEM_TICK');
const SEEN = `${RUN_DIR}/check.seen`;

function seen_read(url) {
	if (TICK == null)
		return {};

	try {
		const j = json(fs.readfile(SEEN) ?? '');

		return (j?.tick == TICK && j?.url == url) ? (j.ok ?? {}) : {};
	}
	catch (e) {
		return {};
	}
}

function seen_write(url, ok) {
	if (TICK == null || !length(ok))
		return;

	const all = { ...seen_read(url), ...ok };
	const tmp = `${SEEN}.${split(fs.readfile('/proc/self/stat') ?? '', ' ')[0]}`;

	if (fs.writefile(tmp, sprintf('%J', { tick: TICK, url: url, ok: all })) != null)
		fs.rename(tmp, SEEN);
}

// Checks all users at once (a curl each, in parallel): a dead server costs
// its timeout once, not once per server. Returns { user: ms } for those that
// answered; the others are missing.
export function works_many(users, url, timeout) {
	const res = {}, fresh = {};
	const seen = seen_read(url);
	let cmd = '';

	for (let i, u in users) {
		if (seen[u] != null) {
			res[u] = seen[u];
			continue;
		}

		cmd += `( echo "${i} $(curl -s -o /dev/null -m ${timeout ?? 6} -x ${q(`socks5h://${u}:${HELPER_PASS}@127.0.0.1:${HELPER_PORT}`)} ` +
			`-w '%{http_code} %{time_total}' ${q(url)} 2>/dev/null)" ) & `;
	}

	if (cmd == '')
		return res;

	for (let l in split(command(cmd + 'wait'), '\n')) {
		const m = match(l, /^([0-9]+) ([0-9]+)( ([0-9.]+))?/);

		if (m && int(m[2]) >= 100 && users[int(m[1])] != null)
			res[users[int(m[1])]] = fresh[users[int(m[1])]] = int((m[4] ?? 0) * 1000) || 1;
	}

	seen_write(url, fresh);

	return res;
};

// One user; a failed check is asked again once at once with a shorter
// timeout: a lost packet should not move the traffic.
export function works(user, url, timeout) {
	return works_many([ user ], url, timeout)[user] != null ||
		works_many([ user ], url, max(3, (timeout ?? 6) - 2))[user] != null;
};
