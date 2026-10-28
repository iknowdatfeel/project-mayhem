// Mayhem: TCP ping of many servers in one process.
//
// The time of a TCP handshake with the server's address and port, as v2rayNG
// measures it, but with the sockets of this process: a curl per server cost a
// process start each, and on a small router a wave of them took longer to
// start than the handshakes they timed (the numbers grew with the wave).
// Here the clock starts at connect() and stops when the kernel reports the
// connection, nothing else in between.
//
// Names are resolved first (dnsmasq usually has them, xray asked for them)
// and not counted. Every target is connected twice, one after the other, and
// the faster handshake counts: the first SYN to an address may wait for ARP,
// NAT or a cold route, which is not the server's delay. At most WAVE
// handshakes at once, never two with one address at once: subscriptions
// often have many servers on one host, whose firewall drops a burst.
// Servers on one address and port share one result. A host that let a
// handshake time out is not waited for again: its other ports get
// "timeout" at once (one by one they took 4 s each, and a call for twenty
// servers on a dead host ran past what LuCI waits for an answer). Nothing
// is started after `budget` ms; what is left gets "timeout".
//
// null when the router has no socket module: the caller uses curl then.

'use strict';

const WAVE = 32;
const TRIES = 2;

function ms_now() {
	const t = clock(true);

	return t[0] * 1000 + t[1] / 1000000;
}

function is_ip4(h) {
	return !!match(h, /^[0-9]+\.[0-9]+\.[0-9]+\.[0-9]+$/);
}

// targets: [ { key, host, port } ]; timeout: ms for one handshake; v6: IPv6
// addresses may be used; budget: ms for the whole call (15 s by default).
// Returns { key: { ms } | { error } }.
export function tcp_ping(targets, timeout, v6, budget) {
	let socket;

	try {
		socket = require('socket');
	}
	catch (e) {
		return null;
	}

	const res = {};
	const addr = {};

	// One lookup per name; an IPv4 address first unless only IPv6 is there.
	for (let t in targets) {
		const h = t.host;

		if (addr[h] != null)
			continue;

		if (is_ip4(h) || index(h, ':') >= 0) {
			addr[h] = { family: index(h, ':') >= 0 ? socket.AF_INET6 : socket.AF_INET, address: h };
			continue;
		}

		const ai = socket.addrinfo(h, null, { socktype: socket.SOCK_STREAM }) ?? [];
		const a4 = filter(ai, (a) => a.family == socket.AF_INET)[0];
		const a6 = v6 ? filter(ai, (a) => a.family == socket.AF_INET6)[0] : null;
		const a = a4 ?? a6;

		addr[h] = a ? { family: a.family, address: a.addr.address } : false;
	}

	const queue = [];
	// ip:port -> the keys sharing its result
	const same = {};

	for (let t in targets) {
		const a = addr[t.host];

		if (!a || (a.family == socket.AF_INET6 && !v6))
			res[t.key] = { error: 'no address' };
		else if (!(t.port > 0 && t.port < 65536))
			res[t.key] = { error: 'no port' };
		else {
			const k = `${a.address} ${+t.port}`;

			if (same[k])
				push(same[k], t.key);
			else {
				same[k] = [ t.key ];
				push(queue, { key: k, ip: a.address, family: a.family, port: +t.port, tries: 0, best: null, err: null });
			}
		}
	}

	const open = [];
	const busy = {};
	// hosts that let a handshake time out
	const silent = {};
	const until = ms_now() + (budget ?? 15000);

	const put = (c, r) => {
		for (let key in same[c.key])
			res[key] = r;
	};

	const finish = (c) => {
		if (c.sock)
			c.sock.close();

		c.sock = null;
		delete busy[c.ip];

		if (c.err == 'timeout' && c.best == null)
			silent[c.ip] = true;

		if (++c.tries < TRIES && c.err == null)
			push(queue, c);
		else
			put(c, c.best != null ? { ms: int(c.best) || 1 } : { error: c.err ?? 'no connection' });
	};

	while (length(queue) || length(open)) {
		// Start what fits: the first waiting target whose address is free.
		for (let i = 0; i < length(queue) && length(open) < WAVE; ) {
			const c = queue[i];

			// A silent host, or no time left: not waited for.
			if ((silent[c.ip] && c.best == null) || ms_now() >= until) {
				splice(queue, i, 1);
				put(c, c.best != null ? { ms: int(c.best) || 1 } : { error: 'timeout' });
				continue;
			}

			if (busy[c.ip]) {
				i++;
				continue;
			}

			splice(queue, i, 1);

			const s = socket.create(c.family, socket.SOCK_STREAM | socket.SOCK_NONBLOCK);

			if (!s) {
				c.err = 'no connection';
				put(c, { error: c.err });
				continue;
			}

			c.sock = s;
			c.start = ms_now();
			busy[c.ip] = true;

			// EINPROGRESS: the handshake is under way.
			if (s.connect({ family: c.family, address: c.ip, port: c.port }) == null && socket.error(true) != 115) {
				c.err = 'no connection';
				finish(c);
				continue;
			}

			push(open, c);
		}

		if (!length(open)) {
			// Everything left waits for a busy address: nothing is, so this
			// cannot happen; but never spin.
			for (let c in queue)
				put(c, { error: 'no connection' });

			splice(queue, 0);

			continue;
		}

		const now = ms_now();
		let wait = timeout;

		for (let c in open)
			wait = min(wait, max(0, c.start + timeout - now));

		const ev = socket.poll(int(wait) || 1, ...map(open, (c) => [ c.sock, socket.POLLOUT, c ])) ?? [];
		const done = {};
		const t = ms_now();

		for (let e in ev) {
			const c = e[2];

			if (!e[1] || c.sock !== e[0])
				continue;

			// Writable: connected, or refused (the error says which).
			const err = c.sock.getopt(socket.SOL_SOCKET, socket.SO_ERROR);

			if (err == 0) {
				const ms = t - c.start;

				c.best = c.best == null ? ms : min(c.best, ms);
			}
			else if (c.best == null)
				c.err = err == 111 ? 'refused' : 'no connection';

			done[c.key] = true;
			finish(c);
		}

		for (let i = length(open) - 1; i >= 0; i--) {
			const c = open[i];

			if (done[c.key])
				splice(open, i, 1);
			else if (t - c.start >= timeout) {
				if (c.best == null)
					c.err = 'timeout';

				splice(open, i, 1);
				finish(c);
			}
		}
	}

	return res;
};
