// Mayhem: URL test over kept-alive connections, while the dashboard is open.
//   ucode warm.uc
//
// The URL test of a single server (probe() in the rpcd plugin) sends two
// requests over one connection through the server and counts the second:
// the first one pays for the handshakes. Here every server keeps such a
// connection open and gets a request on it every PERIOD seconds, so the
// latency on the dashboard is there at once and stays current. It is the
// same number: a request over a connection through the server that is
// already open.
//
// Connections go through xray's local SOCKS inbound, as user <server tag>,
// the way the single URL test does. Only http:// URLs: ucode has no TLS.
// The process ends when the dashboard has not asked for a while (the rpcd
// method "warm" touches ALIVE on every call) or xray is gone.
//
// warm.json: { started, url, tags: [...], results: { tag: { ms | error, at } } }

'use strict';

import * as fs from 'fs';
import * as socket from 'socket';
import * as C from 'mayhem.const';

const RUN = C.RUN_DIR;
const OUT = `${RUN}/warm.json`;
const ALIVE = `${RUN}/warm.alive`;
const NOW = `${RUN}/warm.now`;

const PERIOD = int(getenv('MAYHEM_WARM_PERIOD') ?? 10) * 1000;	// ms between requests of a server
const IDLE = int(getenv('MAYHEM_WARM_IDLE') ?? 60);			// s without the dashboard asking
const TIMEOUT = int(getenv('MAYHEM_WARM_TIMEOUT') ?? 10) * 1000;	// ms for a connection or a request, as the single URL test (curl -m 10)
const MAX = 64;			// servers kept warm
const OPENING = 6;		// connections being set up at once: each costs a handshake with
				// a server (Reality and TLS load the CPU of a small router, and a
				// busy router makes every number worse)

function ms_now() {
	const t = clock(true);

	return t[0] * 1000 + t[1] / 1000000;
}

function read_json(path) {
	try {
		return json(fs.readfile(path) ?? '');
	}
	catch (e) {
		return null;
	}
}

// The servers kept warm: every server of nodes.json with a tag, in order, at
// most MAX. The rpcd method "warm" takes the same ones.
function wanted(state) {
	const out = [], seen = {};

	for (let sn in sort(keys(state?.sections ?? {})))
		for (let n in state.sections[sn].nodes ?? [])
			if (n.tag && !seen[n.tag] && length(out) < MAX) {
				seen[n.tag] = true;
				push(out, { tag: n.tag, address: n.address ?? n.iface ?? n.tag });
			}

	return out;
}

function parse_url(u) {
	const m = match(u ?? '', /^http:\/\/([A-Za-z0-9.-]+)(:([0-9]+))?(\/[^#]*)?$/);

	return m ? { host: m[1], port: int(m[3] ?? 80), path: m[4] ?? '/' } : null;
}

const state0 = read_json(`${RUN}/nodes.json`);
const target = parse_url(state0?.probe_url ?? C.DEFAULT_PROBE_URL);

if (!target)
	exit(0);

const request = `GET ${target.path} HTTP/1.1\r\nHost: ${target.host}${target.port == 80 ? '' : ':' + target.port}\r\n` +
	'User-Agent: curl/8\r\nAccept: */*\r\nConnection: keep-alive\r\n\r\n';
const socks_auth = (user) => chr(1, length(user)) + user + chr(length(C.HELPER_PASS)) + C.HELPER_PASS;
const socks_connect = chr(5, 1, 0, 3, length(target.host)) + target.host + chr(target.port >> 8, target.port & 255);

const started = time();
const nodes = {};		// tag -> state of its connection
const results = {};
let tags = [];
let nodes_mtime = 0;
let dirty = true, written = 0;

function result(n, r) {
	r.at = time();
	results[n.tag] = r;
	dirty = true;
}

function close_conn(n) {
	if (n.sock)
		n.sock.close();

	n.sock = null;
	n.phase = 'idle';
	n.buf = '';
}

function fail(n, error) {
	close_conn(n);
	result(n, { error: error });
	n.next = ms_now() + PERIOD;
}

function send(n, data) {
	if (n.sock.send(data, socket.MSG_DONTWAIT | socket.MSG_NOSIGNAL) != length(data)) {
		fail(n, 'no connection');
		return false;
	}

	return true;
}

function sync_nodes() {
	const st = fs.stat(`${RUN}/nodes.json`);

	if (!st || st.mtime == nodes_mtime)
		return;

	nodes_mtime = st.mtime;

	const want = wanted(read_json(`${RUN}/nodes.json`));
	const keep = {};
	let i = 0;

	for (let w in want) {
		keep[w.tag] = true;

		if (!nodes[w.tag])
			// The first checks spread over a second, the handshakes are
			// limited by OPENING anyway.
			nodes[w.tag] = { tag: w.tag, address: w.address, phase: 'idle', buf: '', next: ms_now() + (i++ * 1000 / (length(want) || 1)) };
		else
			nodes[w.tag].address = w.address;
	}

	for (let tag in keys(nodes))
		if (!keep[tag]) {
			close_conn(nodes[tag]);
			delete nodes[tag];
			delete results[tag];
			dirty = true;
		}

	tags = map(want, (w) => w.tag);
	dirty = true;
}

// A connection is being set up until its first request is answered: xray
// answers the SOCKS request at once and connects to the server when the
// first data comes.
function opening(n) {
	return n.sock != null && (substr(n.phase, 0, 6) == 'socks-' || (n.phase == 'request' && n.fresh));
}

function opening_count(address) {
	let all = 0, same = 0;

	for (let tag, n in nodes)
		if (opening(n)) {
			all++;

			if (n.address == address)
				same++;
		}

	return [ all, same ];
}

function start_request(n, fresh) {
	n.phase = 'request';
	n.fresh = fresh;
	n.buf = '';
	n.sent = ms_now();
	n.deadline = n.sent + TIMEOUT;
	n.first = null;
	send(n, request);
}

// Opens the connection, or sends the next request over the open one.
function begin(n) {
	if (n.sock && n.phase == 'ready')
		return start_request(n, false);

	// One handshake per server address at a time: subscriptions often have
	// many servers on one host, and a burst of connections to it makes its
	// firewall drop some.
	const c = opening_count(n.address);

	if (c[0] >= OPENING || c[1] > 0) {
		n.next = ms_now() + 200;
		return;
	}

	n.sock = socket.connect('127.0.0.1', C.HELPER_PORT, { socktype: socket.SOCK_STREAM }, 1000);

	if (!n.sock)
		return fail(n, 'no connection');

	n.phase = 'socks-method';
	n.buf = '';
	n.deadline = ms_now() + TIMEOUT;
	send(n, chr(5, 1, 2));
}

// The response: status, headers, then the body by Content-Length or chunks.
// Returns true when it is complete; n.keep says whether the connection can
// carry the next request.
function response_done(n) {
	if (n.status == null) {
		const end = index(n.buf, '\r\n\r\n');

		if (end < 0)
			return false;

		const head = substr(n.buf, 0, end);
		const m = match(head, /^HTTP\/1\.[01] ([0-9]{3})/);

		if (!m) {
			n.status = 0;
			n.keep = false;
			return true;
		}

		n.status = int(m[1]);
		n.buf = substr(n.buf, end + 4);
		n.keep = !match(head, /\r\n[Cc]onnection:[ \t]*close/);

		const cl = match(head, /\r\n[Cc]ontent-[Ll]ength:[ \t]*([0-9]+)/);

		n.chunked = !!match(head, /\r\n[Tt]ransfer-[Ee]ncoding:[ \t]*chunked/);
		n.left = (n.status == 204 || n.status == 304 || n.status < 200) ? 0 : (cl ? int(cl[1]) : null);

		// Neither a length nor chunks: the body ends with the connection.
		if (n.left == null && !n.chunked)
			n.keep = false;
	}

	if (n.chunked)
		return index(n.buf, '0\r\n\r\n') == 0 || index(n.buf, '\r\n0\r\n\r\n') >= 0;

	if (n.left != null)
		return length(n.buf) >= n.left;

	return false;
}

function finish_request(n) {
	const ok = n.status >= 200 && n.status < 400;

	if (!ok)
		result(n, { error: n.status ? `HTTP ${n.status}` : 'timeout' });
	// After a new connection the first request also opened the connection
	// to the site through the server: only the next one counts. A site that
	// closes the connection after every answer leaves only the first one.
	else if (!n.fresh || !n.keep)
		result(n, { ms: int(n.first - n.sent) || 1 });

	n.status = null;

	if (!n.keep) {
		close_conn(n);

		n.next = ms_now() + PERIOD;
		return;
	}

	n.phase = 'ready';
	n.buf = '';

	if (ok && n.fresh)
		start_request(n, false);
	else
		n.next = ms_now() + PERIOD;
}

function on_data(n, data) {
	n.buf += data;

	switch (n.phase) {
	case 'socks-method':
		if (length(n.buf) < 2)
			return;

		if (substr(n.buf, 0, 2) != chr(5, 2))
			return fail(n, 'no connection');

		n.buf = '';
		n.phase = 'socks-auth';
		send(n, socks_auth(n.tag));
		return;

	case 'socks-auth':
		if (length(n.buf) < 2)
			return;

		if (substr(n.buf, 0, 2) != chr(1, 0))
			return fail(n, 'no connection');

		n.buf = '';
		n.phase = 'socks-connect';
		send(n, socks_connect);
		return;

	case 'socks-connect': {
		if (length(n.buf) < 5)
			return;

		if (ord(n.buf, 1) != 0)
			return fail(n, 'no connection');

		const atyp = ord(n.buf, 3);
		const need = atyp == 1 ? 10 : atyp == 4 ? 22 : 7 + ord(n.buf, 4);

		if (length(n.buf) < need)
			return;

		n.buf = '';
		return start_request(n, true);
	}

	case 'request':
		n.first ??= ms_now();

		if (response_done(n))
			finish_request(n);

		return;

	default:
		// Data on an idle connection: not HTTP as expected.
		return close_conn(n);
	}
}

function write_out() {
	const now = time();

	if (!dirty || now == written)
		return;

	const tmp = `${OUT}.tmp`;

	fs.writefile(tmp, sprintf('%J\n', { started: started, url: state0?.probe_url ?? C.DEFAULT_PROBE_URL, period: PERIOD / 1000, tags: tags, results: results }));
	fs.rename(tmp, OUT);
	dirty = false;
	written = now;
}

function xray_running() {
	const pid = trim(fs.readfile(`${RUN}/xray.pid`) ?? '');

	return pid != '' && fs.access(`/proc/${pid}`);
}

let last_check = 0;

while (true) {
	const now = ms_now();

	// Once a second: is the dashboard still there, did the servers change.
	if (now - last_check >= 1000) {
		last_check = now;

		const alive = fs.stat(ALIVE);

		if (!alive || time() - alive.mtime > IDLE || !xray_running())
			break;

		sync_nodes();
	}

	// The button on the dashboard: everything at once (a quarter of a
	// second at most, see the wait below).
	if (fs.access(NOW)) {
		fs.unlink(NOW);

		for (let tag, n in nodes)
			if (n.phase == 'idle' || n.phase == 'ready')
				n.next = now;
	}

	for (let tag, n in nodes) {
		if ((n.phase == 'idle' || n.phase == 'ready') && n.next <= now)
			begin(n);
		else if (n.sock && n.phase != 'ready' && n.phase != 'idle' && now > n.deadline)
			fail(n, 'timeout');
	}

	write_out();

	const polled = [];
	let wait = 250;

	for (let tag, n in nodes) {
		if (n.sock)
			push(polled, [ n.sock, socket.POLLIN | socket.POLLERR | socket.POLLHUP, n ]);

		if (n.phase == 'idle' || n.phase == 'ready')
			wait = min(wait, max(0, n.next - now));
	}

	const ev = length(polled) ? socket.poll(int(wait) || 1, ...polled) : (sleep(int(wait) || 1), []);

	for (let e in ev ?? []) {
		const n = e[2];

		if (!e[1] || n.sock !== e[0])
			continue;

		const data = n.sock.recv(16384, socket.MSG_DONTWAIT);

		if (data == null)
			continue;

		if (data == '') {
			// The other side closed: a connection that was waiting is
			// opened again; one in the middle of something failed.
			if (n.phase == 'ready') {
				close_conn(n);
				n.next = ms_now();
			}
			else if (n.phase == 'request' && n.status != null && n.left == null && !n.chunked) {
				finish_request(n);
			}
			else
				fail(n, n.phase == 'request' ? 'timeout' : 'no connection');

			continue;
		}

		on_data(n, data);
	}
}

for (let tag, n in nodes)
	close_conn(n);

write_out();
