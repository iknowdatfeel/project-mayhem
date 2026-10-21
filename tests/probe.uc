// Latency checks of the rpcd backend with fake ping and curl (tests/probe.sh
// puts them first in PATH): ICMP of many servers in one call, one ping per
// address, all at once; TCP ping counts the second connection. Prints what
// went wrong; no output means all is well.
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
		{ tag: 'awg0', iface: 'awg0' }
	] }
} }));

// --- ICMP --------------------------------------------------------------------------
fs.writefile(log, '');

const t0 = clock(true);
let r = call('probe_icmp', { tags: [ 'n-a', 'n-a2', 'n-dead1', 'n-dead2', 'n-dead3', 'n-bad', 'awg0', 'n-none' ] });
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
expect(`icmp: one ping per address, ${length(pings)}: ${pings}`, length(pings) == 6);
expect('icmp: the tunnel ping goes through its interface', length(filter(pings, (l) => match(l, /-I awg0 .*1\.1\.1\.1/))) == 1);
// three dead addresses wait 2 s each: at once that is about 2 s, one after
// another 6 s; the tunnel fallback adds one more wave
expect(`icmp: pings run at once (${took} s)`, took < 5);

// --- TCP: the second connection counts -----------------------------------------------
fs.writefile(log, '');
fs.writefile(`${run}/curl.seq`, '0.001 0.050\n0.001 0.020\n');
r = call('probe', { tag: 'n-a', method: 'tcp' });
expect(`tcp: second connection ${r.ms} ${r.error}`, r.ms == 19);

fs.writefile(`${run}/curl.seq`, '0.001 0.050\n0.000 0.000\n');
r = call('probe', { tag: 'n-a', method: 'tcp' });
expect(`tcp: first connection when the second fails ${r.ms} ${r.error}`, r.ms == 49);

fs.writefile(`${run}/curl.seq`, '0.000 0.000\n');
r = call('probe', { tag: 'n-a', method: 'tcp' });
expect(`tcp: no connection ${r.ms} ${r.error}`, r.error == 'no connection');

exit(fails ? 1 : 0);
