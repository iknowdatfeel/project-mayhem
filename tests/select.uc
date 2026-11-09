// The real rpcd methods select_node and set_select (tests/select.sh sets up
// the stand-ins). Prints what went wrong; no output means all is well.
//   ucode tests/select.uc PLUGIN
'use strict';

import * as fs from 'fs';

const stub = getenv('STUB');
const run = getenv('MAYHEM_RUN_DIR');
const plugin = loadfile(ARGV[0])()['luci.mayhem'];
const call = (m, args) => plugin[m].call({ args: args });
let fails = 0;

function expect(what, cond, detail) {
	if (!cond) {
		print(`FAIL ${what}${detail != null ? ': ' + detail : ''}\n`);
		fails++;
	}
}

const read = (f) => fs.readfile(f) ?? '';
const rjson = (f) => json(read(f) || 'null');

function uci(opt) {
	const c = require('uci').cursor(getenv('MAYHEM_UCI_DIR'), getenv('MAYHEM_UCI_SAVE_DIR'));

	c.load('mayhem');

	return c.get('mayhem', ...split(opt, '.'));
}

// Waits up to 3 s for `f` to contain `what`.
function waits(f, what) {
	for (let i = 0; i < 30; i++) {
		if (index(read(f), what) >= 0)
			return true;

		sleep(100);
	}

	return false;
}

function reset(mode) {
	for (let f in [ 'xray.log', 'init.log', 'lib.log' ])
		fs.unlink(`${stub}/${f}`);

	fs.writefile(`${run}/nodes.json`, sprintf('%J', {
		flow_path: { key: 'k', generation: 1 },
		sections: {
			pool: {
				type: 'proxy', mode: mode ?? 'auto', balancer: 'bal-pool', pool: true,
				nodes: [
					{ tag: 'n-pool-a', name: 'A', protocol: 'vless' },
					{ tag: 'n-pool-b', name: 'B', protocol: 'vless' },
					{ tag: 'n-pool-c', name: 'C', protocol: 'vless', source: 'mysub', orig: 'C-orig' },
					{ tag: 'n-pool-t', name: 'Tunnel', protocol: 'interface', iface: 'awg0' }
				]
			}
		}
	}));
	fs.writefile(`${run}/overrides`, '');
	fs.writefile(`${run}/running.overrides`, '');
	fs.unlink(`${run}/health.json`);
	fs.unlink(`${run}/warm.json`);
}

fs.mkdir(run);
// xray "runs": the pid of this process, and the interception is on
fs.writefile(`${run}/xray.pid`, `${fs.readlink('/proc/self')}\n`);
fs.writefile(`${run}/active`, '');

// --- a server by hand, proxy to proxy: in place -------------------------------------
reset();
let r = call('select_node', { section: 'pool', tag: 'n-pool-b' });
let st = rjson(`${run}/nodes.json`);

expect('select: proxy to proxy answers fast', r?.ok && r?.fast, r);
expect('select: xray is told the choice', index(read(`${stub}/xray.log`), 'api bo --server=127.0.0.1:12780 -b bal-pool n-pool-b') >= 0, read(`${stub}/xray.log`));
expect('select: nodes.json has the pinned server', st?.sections?.pool?.override == 'n-pool-b', st?.sections?.pool);
expect('select: the path generation advances', st?.flow_path?.generation == 2, st?.flow_path);
expect('select: the choice is kept for the next start of xray', index(read(`${run}/overrides`), 'bal-pool n-pool-b') >= 0, read(`${run}/overrides`));
expect('select: the choice is saved by name', uci('pool.override') == 'B', uci('pool.override'));
expect('select: no new reconnect epoch on the fast path', uci('settings.reconnect_epoch') == '5', uci('settings.reconnect_epoch'));
expect('select: the new generation goes into the running rules', waits(`${stub}/lib.log`, 'net_generation'), read(`${stub}/lib.log`));
expect('select: no reload on the fast path', read(`${stub}/init.log`) == '', read(`${stub}/init.log`));
expect('select: the section is marked as picked by hand', rjson(`${run}/health.json`)?.sections?.pool?.picked > 0);

// --- a tunnel by hand: the kernel path changes, a reload --------------------------
reset();
r = call('select_node', { section: 'pool', tag: 'n-pool-t' });

expect('select: a tunnel is not the fast path', r?.ok && !r?.fast, r);
expect('select: a tunnel gets a new reconnect epoch', uci('settings.reconnect_epoch') == '6', uci('settings.reconnect_epoch'));
expect('select: a tunnel reloads', waits(`${stub}/init.log`, 'init reload'), read(`${stub}/init.log`));

// --- a fallback chain of the server list -----------------------------------------
// A server of a subscription is named "<subscription>\t<name>"; the first
// item that answered the URL test is pointed at at once, the chain itself
// comes with the reload.
reset();
fs.writefile(`${run}/warm.json`, sprintf('%J', { results: { 'n-pool-c': { ms: 80, at: time() } } }));
r = call('set_select', { section: 'pool', mode: 'fallback', chain: [ 'A', 'mysub\tC' ] });

expect('chain: saved', r?.ok, r);
expect('chain: saved in the configuration', uci('pool.select') == 'fallback' && join(',', uci('pool.chain') ?? []) == 'A,mysub\tC', uci('pool.chain'));
expect('chain: the first item that answers is pointed at at once', index(read(`${stub}/xray.log`), '-b bal-pool n-pool-c') >= 0, read(`${stub}/xray.log`));
expect('chain: the reload builds the chain', waits(`${stub}/init.log`, 'init reload'), read(`${stub}/init.log`));

// None answered: the first server of the chain, never one outside it.
reset();
r = call('set_select', { section: 'pool', mode: 'fallback', chain: [ '@mysub', 'A' ] });

expect('chain: a whole subscription stands for its servers', waits(`${stub}/xray.log`, '-b bal-pool n-pool-c'), read(`${stub}/xray.log`));
expect('chain: a subscription chain reloads too', waits(`${stub}/init.log`, 'init reload'), read(`${stub}/init.log`));

reset();
r = call('set_select', { section: 'pool', mode: 'fallback', chain: [ 'Gone' ] });
sleep(300);

expect('chain: a chain of unknown servers points at nothing', read(`${stub}/xray.log`) == '', read(`${stub}/xray.log`));
expect('chain: a chain of unknown servers still reloads', waits(`${stub}/init.log`, 'init reload'), read(`${stub}/init.log`));

// --- the dashboard shows the server that carries the traffic -----------------------
// health.uc pinned n-pool-c in place of n-pool-a, which xray's checks still
// count as the fastest: the dashboard shows n-pool-c, and the observatory's
// pick again once the pin is from another xray.
reset();
const me = fs.readlink('/proc/self');
fs.writefile(`${run}/health.json`, sprintf('%J', { pid: me, sections: { pool: { down: false, fails: 0, pinned: 'n-pool-c', avoid: [ 'n-pool-a' ] } } }));
let d = call('dashboard', {});
let pool = filter(d?.sections ?? [], (x) => x.name == 'pool')[0];

expect('dashboard: the server health.uc pinned is the active one', pool?.active == 'n-pool-c', pool?.active);

fs.writefile(`${run}/health.json`, sprintf('%J', { pid: '1', sections: { pool: { down: false, fails: 0, pinned: 'n-pool-c' } } }));
d = call('dashboard', {});
pool = filter(d?.sections ?? [], (x) => x.name == 'pool')[0];

expect('dashboard: a pin of another xray does not count', pool?.active == 'n-pool-a', pool?.active);

exit(fails ? 1 : 0);
