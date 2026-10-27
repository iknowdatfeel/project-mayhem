#!/usr/bin/ucode
// Mayhem: what happens when the servers or the remote DNS stop answering.
//
//   health.uc
//
// Run by the scheduler every 20 s while xray works.
//
// Kill switch off (settings.killswitch = 0, the default): a proxy section
// none of whose servers answers sends its traffic direct (its balancer is
// pointed at "direct" in running xray), and so does the remote DNS: dnsmasq
// asks the provider for the names that need it (dns.fallback from the
// generator). Mayhem keeps running, and as soon as a server or the DNS
// answers again everything goes back by itself.
//
// Kill switch on: nothing goes direct, the traffic waits for the servers.
// A section or the DNS that went direct before the switch was turned on is
// put back at once.
//
// When a section is "down":
//   one server or manual choice - the server in use failed two checks in a row;
//   automatic choice            - and xray's own checks know no working server;
//                                 a server pinned by hand that stops answering
//                                 is stood in for by one that works, until it
//                                 answers again;
//   fallback chain              - and none of the chain's servers works.
// A server is checked through the helper proxy with its own tag as the user
// (a GET of the check URL, like a URL test). While a section is down, up to
// two of its servers are tried per run: those xray saw working first.

'use strict';

import * as fs from 'fs';
import { RUN_DIR, API_PORT, METRICS_PORT, HELPER_PORT, HELPER_PASS, DEFAULT_PROBE_URL } from 'mayhem.const';

const XRAY = getenv('MAYHEM_XRAY_BIN') ?? '/usr/libexec/mayhem/xray';
const LIB = getenv('MAYHEM_LIB_DIR') ?? '/usr/share/mayhem';
const FAILS = 2;
const TRIES = 2;

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
const pid = trim(fs.readfile(`${RUN_DIR}/xray.pid`) ?? '');

if (!state || !fs.access(`${RUN_DIR}/active`) || pid == '')
	exit(0);

// One check at a time: the scheduler's and one started by a choice on the
// dashboard may meet. A lock left by a process that is gone is taken over.
const LOCK = `${RUN_DIR}/health.lock`;

if (!fs.mkdir(LOCK)) {
	const owner = trim(fs.readfile(`${LOCK}/pid`) ?? '');

	if (owner != '' && fs.access(`/proc/${owner}`))
		exit(0);
}

fs.writefile(`${LOCK}/pid`, `${fs.readfile('/proc/self/stat') ? split(fs.readfile('/proc/self/stat'), ' ')[0] : ''}\n`);

function unlock() {
	fs.unlink(`${LOCK}/pid`);
	fs.rmdir(LOCK);
}

const ks = state.killswitch == true;
const started = time();
let h = read_json('health.json') ?? {};

// Another xray: its balancers start from the saved choices, nothing in it
// goes direct yet.
if (h.pid != pid)
	h = { pid: pid, sections: {}, dns: h.dns };

if (type(h.sections) != 'object')
	h.sections = {};

if (type(h.dns) != 'object')
	h.dns = {};

const url = match(state.probe_url ?? '', /^https?:\/\//) ? state.probe_url : DEFAULT_PROBE_URL;

// GET of the check URL through the helper proxy as user `user`: a server
// tag, or sec-<section> for the section's own path.
function works(user) {
	const out = trim(command(`curl -s -o /dev/null -m 6 -x ${q(`socks5h://${user}:${HELPER_PASS}@127.0.0.1:${HELPER_PORT}`)} -w '%{http_code}' ${q(url)} 2>/dev/null`));
	const code = int(out);

	return code >= 200 && code < 400;
}

function bo(bal, tag) {
	return system(`${XRAY} api bo --server=127.0.0.1:${API_PORT} -b ${q(bal)} ${tag ? q(tag) : '-r'} >/dev/null 2>&1`) == 0;
}

let obs = null;

function observatory() {
	if (obs == null) {
		try {
			obs = json(command(`curl -s -m 3 http://127.0.0.1:${METRICS_PORT}/debug/vars`))?.observatory ?? {};
		}
		catch (e) {
			obs = {};
		}
	}

	return obs;
}

// The server a section uses when nothing goes direct.
function in_use(sn, s) {
	const tags = map(s.nodes, (n) => n.tag);

	if (s.mode == 'fallback') {
		const now = read_json('fallback.json')?.[sn];

		return index(tags, now) >= 0 ? now : s.selected;
	}

	if (s.mode == 'manual')
		return s.selected;

	if (s.override)
		return h.sections?.[sn]?.stand_in?.tag ?? s.override;

	let best = null;
	const o = observatory();

	for (let t in tags)
		if (o[t]?.alive && (!best || o[t].delay < o[best].delay))
			best = t;

	return best ?? tags[0];
}

// The servers that may take a section's traffic.
function members(s) {
	if (s.mode == 'manual' || s.mode == 'single')
		return [ s.selected ?? s.nodes[0].tag ];

	if (s.mode == 'fallback' && length(s.chain ?? []))
		return s.chain;

	return map(s.nodes, (n) => n.tag);
}

// The choice the balancer had before it went direct. In automatic mode the
// server that answered is pinned for a while (`pin`) when xray's own checks
// know no working server yet: the balancer would take its fallback, the
// first server, which may be the dead one.
function restore(sn, s, tag, pin) {
	const bal = s.balancer ?? `bal-${sn}`;

	if (s.mode == 'fallback') {
		const fb = read_json('fallback.json') ?? {};

		fb[sn] = tag;
		write('fallback.json', sprintf('%J\n', fb));

		return bo(bal, tag);
	}

	if (s.mode == 'manual')
		return bo(bal, s.selected);

	// The server pinned by hand still does not answer: the one that does
	// stands in for it.
	if (s.mode == 'auto' && s.override && tag && tag != s.override)
		return bo(bal, tag) ? 'stand_in' : false;

	if (pin && !s.override && s.mode == 'auto') {
		const o = observatory();

		if (!length(filter(map(s.nodes, (n) => n.tag), (t) => o[t]?.alive == true)))
			return bo(bal, tag) ? 'pinned' : false;
	}

	return bo(bal, s.override);
}

// What makes the balancer change behind our back: a choice on the
// dashboard, a reload (live.uc applies the choices again).
const mark = (s) => `${state.generated ?? ''} ${s.selected ?? ''} ${s.override ?? ''}`;

const names = (s, tags) => join(', ', map(tags, (t) => filter(s.nodes, (n) => n.tag == t)[0]?.name ?? t));

for (let sn in keys(state.sections ?? {})) {
	const s = state.sections[sn];

	if (s.type != 'proxy' || !length(s.nodes ?? []))
		continue;

	const bal = s.balancer ?? `bal-${sn}`;
	if (type(h.sections[sn]) != 'object')
		h.sections[sn] = { down: false, fails: 0 };

	const hs = h.sections[sn];

	if (ks) {
		if (hs.down || hs.stand_in) {
			delete hs.stand_in;
			restore(sn, s, s.override ?? in_use(sn, s));

			if (hs.down)
				log(`section ${sn}: the kill switch is on, its traffic waits for the servers instead of going direct`);
		}

		h.sections[sn] = { down: false, fails: 0 };
		continue;
	}

	// A server pinned by hand that stopped answering, and the one standing in
	// for it: back to the pinned one as soon as it answers again. A new
	// choice ends the stand-in; a reload (live.uc puts the choices in again)
	// points the balancer at the stand-in once more.
	if (!hs.down && hs.stand_in) {
		const si = hs.stand_in;

		if (si.pin != s.override || index(map(s.nodes, (n) => n.tag), si.tag) < 0)
			delete hs.stand_in;
		else if (works(s.override)) {
			if (bo(bal, s.override)) {
				log(`section ${sn}: ${names(s, [ s.override ])} answers again, its traffic goes through it again`);
				delete hs.stand_in;
				hs.fails = 0;
				continue;
			}
		}
		else if (si.mark != mark(s) && bo(bal, si.tag))
			si.mark = mark(s);
	}

	if (!hs.down) {
		// A server pinned on the way back from direct is let go once xray's
		// checks see a working server.
		if (hs.pinned) {
			const o = observatory();

			if (index(map(s.nodes, (n) => n.tag), hs.pinned) < 0)
				delete hs.pinned;
			else if (length(filter(s.nodes, (n) => o[n.tag]?.alive == true)) && bo(bal, s.override))
				delete hs.pinned;
		}

		if (works(hs.pinned ?? in_use(sn, s))) {
			hs.fails = 0;
			continue;
		}

		if (++hs.fails < FAILS)
			continue;

		// Automatic choice and chains: another server xray saw working
		// takes over by itself - if it really works (xray checks each
		// server once per interval, minutes apart).
		if (s.mode != 'manual' && s.mode != 'single') {
			const o = observatory();
			const others = filter(members(s), (t) => t != in_use(sn, s) && o[t]?.alive == true);
			let other = false;

			for (let t in slice(others, 0, TRIES + 1))
				if (works(t)) {
					other = t;
					break;
				}

			if (other) {
				// The balancer takes it by itself, but not past a server
				// pinned by hand: that one gets a stand-in.
				if (s.mode == 'auto' && s.override) {
					if (other == s.override) {
						if (bo(bal, s.override))
							delete hs.stand_in;
					}
					else if (bo(bal, other)) {
						hs.stand_in = { pin: s.override, tag: other, mark: mark(s) };
						hs.fails = 0;
						log(`section ${sn}: the pinned server ${names(s, [ s.override ])} does not answer, ${names(s, [ other ])} stands in for it until it does`, 'warn');
					}
				}

				continue;
			}
		}

		if (!bo(bal, 'direct')) {
			log(`section ${sn}: its servers do not answer, but xray did not take "direct"`, 'warn');
			continue;
		}

		hs.down = true;
		hs.fails = 0;
		hs.since = time();
		delete hs.stand_in;
		hs.mark = mark(s);
		hs.next = 0;
		log(`section ${sn}: no server answers (${names(s, members(s))}), its traffic goes direct until one does`, 'warn');
		continue;
	}

	// Down: try the servers, those xray saw working first, then the rest
	// in turn.
	const o = observatory();
	const all = members(s);
	const seen = sort(filter(all, (t) => o[t]?.alive == true), (a, b) => (o[a].delay ?? 0) - (o[b].delay ?? 0));
	const rest = filter(all, (t) => index(seen, t) < 0);
	// One server xray saw working, the others in turn: every server gets
	// its try within a few runs.
	const tries = slice(seen, 0, 1);
	let taken = 0;

	for (let i = 0; length(tries) < TRIES && i < length(rest); i++, taken++)
		push(tries, rest[((hs.next ?? 0) + i) % length(rest)]);

	hs.next = ((hs.next ?? 0) + taken) % (length(rest) || 1);

	let good = null;

	for (let t in tries)
		if (works(t)) {
			good = t;
			break;
		}

	if (good) {
		const r = restore(sn, s, good, true);

		if (r) {
			log(`section ${sn}: ${names(s, [ good ])} answers again, its traffic goes through the servers`);
			h.sections[sn] = { down: false, fails: 0 };

			if (r == 'pinned')
				h.sections[sn].pinned = good;
			else if (r == 'stand_in')
				h.sections[sn].stand_in = { pin: s.override, tag: good, mark: mark(s) };
		}

		continue;
	}

	// Still down, but someone pointed the balancer elsewhere meanwhile.
	if (hs.mark != mark(s) && bo(bal, 'direct'))
		hs.mark = mark(s);
}

// Sections that are gone.
for (let sn in keys(h.sections))
	if (!state.sections?.[sn])
		delete h.sections[sn];

// --- remote DNS ------------------------------------------------------------------

// A DNS query for the check URL's host, in the wire format (RFC 8484 GET).
function doh_query() {
	const host = match(url, /^https?:\/\/([^/:]+)/)?.[1] ?? 'www.gstatic.com';
	let q = '\0\0\x01\0\0\x01\0\0\0\0\0\0';

	for (let l in split(host, '.'))
		if (length(l))
			q += chr(length(l)) + l;

	q += '\0\0\x01\0\x01';

	return replace(replace(replace(b64enc(q), /\+/g, '-'), /\//g, '_'), /=+$/, '');
}

// null: cannot tell from here (the path decides, and that is the section's).
function dns_works(srv, via) {
	if (match(srv.address, /^https:\/\//)) {
		const proxy = via ? `-x ${q(`socks5h://${via}:${HELPER_PASS}@127.0.0.1:${HELPER_PORT}`)}` : '';
		const sep = index(srv.address, '?') >= 0 ? '&' : '?';
		const code = int(trim(command(`curl -s -o /dev/null -m 6 ${proxy} -H 'accept: application/dns-message' -w '%{http_code}' ${q(srv.address + sep + 'dns=' + doh_query())} 2>/dev/null`)));

		return code == 200;
	}

	// UDP or TCP through a server: the helper proxy carries neither.
	if (via || (srv.port && srv.port != 53))
		return null;

	const host = match(url, /^https?:\/\/([^/:]+)/)?.[1] ?? 'www.gstatic.com';

	return system(`nslookup ${q(host)} ${q(srv.host)} 2>/dev/null | grep -q '^Name:'`) == 0;
}

const dc = state.dns_check;
const d = h.dns;
let dns_changed = false;

if (!dc || ks) {
	if (d.down) {
		fs.unlink(`${RUN_DIR}/dns.degraded`);
		dns_changed = true;
		log(ks ? 'remote DNS: the kill switch is on, names wait for it instead of going to the provider'
			: 'remote DNS: back to the remote servers');
	}

	h.dns = {};
}
else {
	let ok = false, known = false;

	for (let srv in dc.servers ?? []) {
		const r = dns_works(srv, dc.via);

		if (r == null)
			continue;

		known = true;

		if (r) {
			ok = true;
			break;
		}
	}

	if (!known || ok) {
		if (d.down) {
			fs.unlink(`${RUN_DIR}/dns.degraded`);
			dns_changed = true;
			log('remote DNS answers again, names go to it again');
		}

		h.dns = {};
	}
	else if (!d.down && ++d.fails >= FAILS) {
		fs.writefile(`${RUN_DIR}/dns.degraded`, `${time()}\n`);
		d.down = true;
		d.since = time();
		dns_changed = true;
		log(`remote DNS does not answer (${join(', ', map(dc.servers, (x) => x.address))}), names go to the provider's DNS until it does`, 'warn');
	}
}

if (dns_changed)
	system(`sh -c ${q(`. ${LIB}/lib.sh; mayhem_dns_servers xray`)} >/dev/null 2>&1`);

// A server chosen on the dashboard while this check ran: that choice wins
// over what this check saw for the section.
const disk = read_json('health.json');

for (let sn in keys(disk?.sections ?? {}))
	if ((disk.sections[sn]?.picked ?? 0) >= started)
		h.sections[sn] = disk.sections[sn];

write('health.json', sprintf('%J\n', h));
unlock();
exit(0);
