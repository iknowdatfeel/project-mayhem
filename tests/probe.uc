// Latency checks of the rpcd backend with a fake ping (tests/run.sh puts it
// first in PATH): ICMP of many servers in one call, one ping per address, all
// at once; TCP ping with the sockets of the process against local listeners.
// Prints what went wrong; no output means all is well.
//   ucode tests/probe.uc PLUGIN
'use strict';

import * as fs from 'fs';

const plugin = loadfile(ARGV[0])()['luci.mayhem'];
const call = (m, args) => plugin[m].call({ args: args });
const run = getenv('MAYHEM_RUN_DIR');
const log = getenv('FAKE_LOG');
let fails = 0;

function expect(what, cond) {
	if (!cond) {
		print(`${what}\n`);
		fails++;
	}
}

fs.mkdir(run);
fs.writefile(`${run}/nodes.json`, sprintf('%J', { sections: {
	pool: { nodes: [
		{ tag: 'n-a', address: '10.0.0.1', port: 443 },
		{ tag: 'n-a2', address: '10.0.0.1', port: 8443 },
		{ tag: 'n-dead1', address: '10.0.0.2', port: 443 },
		{ tag: 'n-dead2', address: '10.0.0.3', port: 443 },
		{ tag: 'n-dead3', address: '10.0.0.4', port: 443 },
		{ tag: 'n-bad', address: '10.0.0.1;reboot', port: 443 },
		{ tag: 'awg0', iface: 'awg0' },
		{ tag: 'wg9', iface: 'wg9' }
	] }
} }));

// --- ICMP --------------------------------------------------------------------------
fs.writefile(log, '');

const t0 = clock(true);
let r = call('probe_icmp', { tags: [ 'n-a', 'n-a2', 'n-dead1', 'n-dead2', 'n-dead3', 'n-bad', 'awg0', 'wg9', 'n-none' ] });
const took = clock(true)[0] - t0[0];
const res = r.results ?? {};
const pings = filter(split(fs.readfile(log) ?? '', '\n'), (l) => match(l, /^ping /));

expect(`icmp: live server ${res['n-a']}`, res['n-a']?.ms == 12);
expect(`icmp: second server on that address ${res['n-a2']}`, res['n-a2']?.ms == 12);
expect(`icmp: dead server ${res['n-dead1']}`, res['n-dead1']?.error == 'no reply');
expect(`icmp: bad address ${res['n-bad']}`, res['n-bad']?.error == 'no address');
expect(`icmp: unknown server ${res['n-none']}`, res['n-none']?.error == 'unknown server');
// the endpoint 203.0.113.10 does not answer: the tunnel is pinged through itself
expect(`icmp: tunnel through itself ${res['awg0']}`, res['awg0']?.ms == 40);
// the obfuscated tunnel pings its server (10.0.0.1), not 127.0.0.1
expect(`icmp: obfuscated tunnel ${res['wg9']}`, res['wg9']?.ms == 12);
expect(`icmp: one ping per address, ${length(pings)}: ${pings}`, length(pings) == 6 && !match(join(' ', pings), /127\.0\.0\.1/));
expect('icmp: the tunnel ping goes through its interface', length(filter(pings, (l) => match(l, /-I awg0 .*1\.1\.1\.1/))) == 1);
// three dead addresses wait 2 s each: at once that is about 2 s, one after
// another 6 s; the tunnel fallback adds one more wave
expect(`icmp: pings run at once (${took} s)`, took < 5);

// --- TCP: the handshake with the server, sockets of this process --------------------
// A listening socket stands for a live server (the kernel completes the
// handshake), a closed port for a dead one.
const socket = require('socket');
const lsn = socket.listen('127.0.0.1', 0, { socktype: socket.SOCK_STREAM }, 64);
const port = lsn.sockname().port;
const closed = socket.listen('127.0.0.1', 0, { socktype: socket.SOCK_STREAM });
const dead_port = closed.sockname().port;

closed.close();

const st = json(fs.readfile(`${run}/nodes.json`));

push(st.sections.pool.nodes,
	{ tag: 'n-live', address: '127.0.0.1', port: port }, { tag: 'n-live2', address: 'localhost', port: port },
	{ tag: 'n-closed', address: '127.0.0.1', port: dead_port }, { tag: 'n-udp', address: '127.0.0.1', port: port, udp: true },
	{ tag: 'n-noname', address: 'no-such-host.invalid', port: 443 });
fs.writefile(`${run}/nodes.json`, sprintf('%J', st));
fs.writefile(log, '');

r = call('probe', { tag: 'n-live', method: 'tcp' });
expect(`tcp: live server ${r.ms} ${r.error}`, r.ms >= 1 && r.ms < 100);

r = call('probe', { tag: 'n-closed', method: 'tcp' });
expect(`tcp: closed port ${r.ms} ${r.error}`, r.error == 'refused');

const t1 = clock(true);
r = call('probe_tcp', { tags: [ 'n-live', 'n-live2', 'n-closed', 'n-udp', 'n-noname', 'awg0', 'n-none' ] });
const took2 = clock(true)[0] - t1[0];
const rt = r.results ?? {};

expect(`tcp batch: live ${rt['n-live']} ${rt['n-live2']}`, rt['n-live']?.ms >= 1 && rt['n-live2']?.ms >= 1);
expect(`tcp batch: closed ${rt['n-closed']}`, rt['n-closed']?.error == 'refused');
expect(`tcp batch: UDP, no name ${rt['n-udp']} ${rt['n-noname']}`, rt['n-udp']?.error == 'UDP protocol' && rt['n-noname']?.error == 'no address');
expect(`tcp batch: tunnel and unknown ${rt['awg0']} ${rt['n-none']}`, rt['awg0']?.error == 'tunnel' && rt['n-none']?.error == 'unknown server');
expect('tcp batch: no process per server', !match(fs.readfile(log) ?? '', /curl /));
expect(`tcp batch: quick (${took2} s)`, took2 < 3);

lsn.close();

exit(fails ? 1 : 0);
