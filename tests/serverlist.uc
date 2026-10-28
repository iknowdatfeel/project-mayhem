// The rpcd methods of the server list: a server clicked while the list is a
// chain makes it "chosen by hand" (automatic with a pinned server), and the
// chain's window saves the list's chain with the rules of its subscriptions.
// Needs MAYHEM_UCI_DIR with a writable mayhem config and MAYHEM_RUN_DIR.
//   ucode tests/serverlist.uc PLUGIN
'use strict';

import { writefile, readfile, mkdir } from 'fs';

const plugin = loadfile(ARGV[0])()['luci.mayhem'];
const call = (m, args) => plugin[m].call({ args: args });
const dir = getenv('MAYHEM_UCI_DIR');
const run = getenv('MAYHEM_RUN_DIR');
let fails = 0;

function expect(what, cond) {
	if (!cond) {
		print(`${what}\n`);
		fails++;
	}
}

function cursor() {
	const c = require('uci').cursor(dir);

	c.load('mayhem');

	return c;
}

let c = cursor();

c.set('mayhem', 'pool', 'pool');
c.set('mayhem', 'pool', 'select', 'fallback');
c.set('mayhem', 'pool', 'chain', [ '@mysub' ]);
c.set('mayhem', 'mysub', 'subscription');
c.set('mayhem', 'mysub', 'url', 'http://example.invalid/sub');
c.commit('mayhem');

mkdir(run);
writefile(`${run}/nodes.json`, sprintf('%J', { sections: { pool: { type: 'proxy', mode: 'fallback', balancer: 'bal-pool',
	chain: [ 'n-pool-1', 'n-pool-2' ], items: [ { sub: 'mysub', rule: 'auto' } ], nodes: [
	{ tag: 'n-pool-1', name: 'A', source: 'mysub' },
	{ tag: 'n-pool-2', name: 'B', source: 'mysub' },
	{ tag: 'n-pool-3', name: 'K1', source: 'link' } ] } } }));

// The chain's window: the chain and the rule of its subscription at once.
let r = call('set_select', { section: 'pool', mode: 'fallback', chain: [ 'K1', '@mysub' ], rules: { mysub: { mode: 'manual', selected: 'B' } } });
c = cursor();
expect(`set_select with rules: ${r}`, r?.ok);
expect('the chain is not saved', join('|', c.get('mayhem', 'pool', 'chain') ?? []) == 'K1|@mysub');
expect('the rule of the subscription is not saved', c.get('mayhem', 'mysub', 'select') == 'manual' && c.get('mayhem', 'mysub', 'selected') == 'B');

r = call('set_select', { section: 'pool', mode: 'fallback', chain: [ '@mysub' ], rules: { mysub: { mode: 'fallback', chain: [] } } });
expect('an empty chain of a subscription is taken', r?.error);

r = call('set_select', { section: 'pool', mode: 'manual', chain: [] });
expect('the list takes "manual" as a mode of its own', r?.error);

// A click on a server while the list is a chain: chosen by hand.
r = call('select_node', { section: 'pool', tag: 'n-pool-3' });
c = cursor();
expect(`select_node from the chain: ${r}`, r?.ok);
expect('the list is not automatic with the server pinned',
	c.get('mayhem', 'pool', 'select') == 'auto' && c.get('mayhem', 'pool', 'override') == 'K1');

const st = json(readfile(`${run}/nodes.json`));

expect('nodes.json: the list automatic with the server pinned',
	st.sections.pool.mode == 'auto' && st.sections.pool.override == 'n-pool-3' && st.sections.pool.selected == null);
expect('overrides: the choice for the next start', readfile(`${run}/overrides`) == 'bal-pool n-pool-3\n');

exit(fails ? 1 : 0);
