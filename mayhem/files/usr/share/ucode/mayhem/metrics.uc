// Mayhem: xray's metrics endpoint (/debug/vars): the observatory, the
// traffic counters of the outbounds, Go's memory statistics.
//
// One deadline for the whole answer. A stopped or hung xray still has its
// port accept connections (the kernel does that for it), and a read without
// a deadline waited for its answer forever: the scheduler with it - and so
// the watchdog that restarts such an xray - and rpcd with the whole web
// interface.
//
// The request is HTTP/1.0: to HTTP/1.1 Go answers a body of more than 2 KB in
// chunks, which are no JSON (the observatory read over the socket was always
// empty, and curl was asked again).

'use strict';

import * as fs from 'fs';
import { METRICS_PORT } from 'mayhem.const';

function ms_now() {
	const t = clock(true);

	return t[0] * 1000 + t[1] / 1000000;
}

function q(s) {
	return "'" + replace(`${s}`, /'/g, "'\\''") + "'";
}

// "<size>\r\n<data>\r\n...0\r\n\r\n" -> the data; null when cut short.
function dechunk(body) {
	let out = '', pos = 0;

	while (true) {
		const nl = index(substr(body, pos), '\r\n');

		if (nl < 0)
			return null;

		const size = hex(trim(split(substr(body, pos, nl), ';')[0]));

		if (type(size) != 'int' || size < 0)
			return null;

		if (size == 0)
			return out;

		pos += nl + 2;

		if (length(body) < pos + size)
			return null;

		out += substr(body, pos, size);
		pos += size + 2;
	}
}

// The body of an HTTP answer; null unless it is a complete 200.
function body_of(buf) {
	const end = index(buf, '\r\n\r\n');

	if (end < 0 || !match(buf, /^HTTP\/1\.[01] 200/))
		return null;

	const head = substr(buf, 0, end);
	const body = substr(buf, end + 4);

	return match(head, /\r\n[Tt]ransfer-[Ee]ncoding:[ \t]*chunked/) ? dechunk(body) : body;
}

function via_socket(ms) {
	let s;

	try {
		s = require('socket');
	}
	catch (e) {
		return false;
	}

	const deadline = ms_now() + ms;
	const sock = s.connect('127.0.0.1', METRICS_PORT, { socktype: s.SOCK_STREAM }, min(ms, 1500));

	// Not even connected: curl is asked (it costs little when nothing
	// listens). One that connected and then said nothing is not.
	if (!sock)
		return false;

	let buf = '', done = false;

	if (sock.send('GET /debug/vars HTTP/1.0\r\nHost: 127.0.0.1\r\n\r\n') != null) {
		while (true) {
			const left = int(deadline - ms_now());

			if (left <= 0)
				break;

			const ev = s.poll(left, [ sock, s.POLLIN ]);

			// Nothing within the deadline.
			if (!length(ev ?? []) || !ev[0][1])
				break;

			const chunk = sock.recv(65536, s.MSG_DONTWAIT);

			if (chunk == null)
				break;

			if (chunk == '') {
				done = true;
				break;
			}

			buf += chunk;
		}
	}

	sock.close();

	return done ? body_of(buf) : null;
}

// The parsed /debug/vars, or null when xray did not answer within `ms`
// milliseconds (2000 by default).
export function vars(ms) {
	ms ??= 2000;

	let text = via_socket(ms);

	// No socket module (the mayhem package does not need one), or no
	// connection: curl.
	if (text === false) {
		const p = fs.popen(`curl -s -m ${q(max(1, int((ms + 999) / 1000)))} http://127.0.0.1:${METRICS_PORT}/debug/vars 2>/dev/null`, 'r');

		text = p ? p.read('all') : null;
		p?.close();
	}

	try {
		const j = json(text ?? '');

		return type(j) == 'object' ? j : null;
	}
	catch (e) {
		return null;
	}
};

// What xray's observatory saw of every server it checks ({} when xray did
// not answer).
export function observatory(ms) {
	return vars(ms)?.observatory ?? {};
};

// Parses text that curl printed (a caller that already has it).
export function parse(text) {
	try {
		const j = json(text ?? '');

		return type(j) == 'object' ? j : null;
	}
	catch (e) {
		return null;
	}
};
