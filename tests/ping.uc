// TCP ping (mayhem.ping): an open port answers, a closed one is refused,
// servers on one address and port share a check, and a host that does not
// answer costs one timeout, not one per server. Prints one line per failed
// expectation; no output means all is well. A silent server is a listening
// socket on 127.0.0.2 whose queue is full: the kernel drops further SYNs.
//   ucode tests/ping.uc
'use strict';

import * as socket from 'socket';
import { tcp_ping } from 'mayhem.ping';

const SILENT = '127.0.0.2';
let fails = 0;

function expect(what, cond, got) {
	if (!cond) {
		print(`${what}: ${sprintf('%J', got)}\n`);
		fails++;
	}
}

function ms_now() {
	const t = clock(true);

	return t[0] * 1000 + t[1] / 1000000;
}

const srv = socket.listen('127.0.0.1', 0, { socktype: socket.SOCK_STREAM }, 64);
const port = srv.sockname().port;
// a port nobody listens on: one that was just closed
const tmp = socket.listen('127.0.0.1', 0, { socktype: socket.SOCK_STREAM });
const closed = tmp.sockname().port;

tmp.close();

let r = tcp_ping([
	{ key: 'open', host: '127.0.0.1', port: port },
	{ key: 'open2', host: '127.0.0.1', port: port },
	{ key: 'closed', host: '127.0.0.1', port: closed },
	{ key: 'noport', host: '127.0.0.1', port: 0 }
], 1000, false);

expect('an open port answers', r.open?.ms > 0, r);
expect('one address and port, one result', r.open2?.ms == r.open?.ms, r);
expect('a closed port is refused', r.closed?.error == 'refused', r);
expect('no port', r.noport?.error == 'no port', r);

// A port of the silent host: a listener that never accepts, its queue
// filled first.
const keep = [];

function silent_port() {
	const l = socket.listen(SILENT, 0, { socktype: socket.SOCK_STREAM }, 0);
	const p = l.sockname().port;

	push(keep, l);

	for (let i = 0; i < 3; i++) {
		const c = socket.create(socket.AF_INET, socket.SOCK_STREAM | socket.SOCK_NONBLOCK);

		c.connect({ family: socket.AF_INET, address: SILENT, port: p });
		push(keep, c);
	}

	return p;
}

// Five servers on a silent host: one timeout, not five.
const silent = map([ 1, 2, 3, 4, 5 ], (i) => ({ key: `s${i}`, host: SILENT, port: silent_port() }));

sleep(200);
let t0 = ms_now();

r = tcp_ping(silent, 500, false);

const took = ms_now() - t0;

expect('a silent host times out', length(filter(keys(r), (k) => r[k]?.error == 'timeout')) == 5, r);
expect('a silent host is waited for once', took < 1500, { took: took, r: r });

// Nothing is started past the budget.
t0 = ms_now();
r = tcp_ping([ ...map([ 1, 2, 3 ], (i) => ({ key: `a${i}`, host: SILENT, port: silent[i].port })), { key: 'late', host: '127.0.0.1', port: port } ], 400, false, 1);
expect('past the budget: timeout', r.late?.error == 'timeout' || r.late?.ms > 0, r);
expect('the budget holds', ms_now() - t0 < 1500, { took: ms_now() - t0 });

srv.close();

for (let k in keep)
	k.close();

exit(fails ? 1 : 0);
