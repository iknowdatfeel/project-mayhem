// Servers deleted from a subscription: server_delete keeps the provider's
// name with the subscription, server_restore brings them back. Needs
// MAYHEM_UCI_DIR with a writable mayhem config and MAYHEM_RUN_DIR. Prints
// what went wrong.
//   ucode tests/hidden.uc PLUGIN
'use strict';

import { writefile, mkdir } from 'fs';

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
c.set('mayhem', 'mysub', 'subscription');
c.set('mayhem', 'mysub', 'url', 'http://example.invalid/sub');
c.commit('mayhem');

mkdir(run);
writefile(`${run}/nodes.json`, sprintf('%J', { sections: { pool: { type: 'proxy', nodes: [
	{ tag: 'n-pool-1', name: 'Alias A', orig: 'Server A', source: 'mysub', usec: 'pool' },
	{ tag: 'n-pool-2', name: 'Server (B).x', orig: 'Server (B).x', source: 'mysub', usec: 'pool' } ] } } }));

let r = call('server_delete', { section: 'pool', tag: 'n-pool-1' });
c = cursor();
expect(`delete A: ${r.error}`, r.ok === true);
expect('delete A: the provider name is kept with the subscription', index(c.get('mayhem', 'mysub', 'hidden') ?? [], 'Server A') >= 0);
expect('delete A: the exclusions of the section stay untouched', c.get('mayhem', 'pool', 'exclude') == null);

r = call('server_delete', { section: 'pool', tag: 'n-pool-2' });
c = cursor();
expect(`delete B: ${r.error}`, r.ok === true);
expect('delete B: both are kept', length(c.get('mayhem', 'mysub', 'hidden') ?? []) == 2);

r = call('server_restore', { subscription: 'mysub', name: 'Server A' });
c = cursor();
expect(`restore one: ${r.error}`, r.ok === true && length(r.hidden) == 1 && r.hidden[0] == 'Server (B).x');
expect('restore one: only that server is back', length(c.get('mayhem', 'mysub', 'hidden') ?? []) == 1);

expect('restore: a server that is not deleted is refused', call('server_restore', { subscription: 'mysub', name: 'Server A' }).error != null);
expect('restore: an unknown subscription is refused', call('server_restore', { subscription: 'nosub', name: '' }).error != null);

r = call('server_restore', { subscription: 'mysub', name: '' });
c = cursor();
expect(`restore all: ${r.error}`, r.ok === true && length(r.hidden) == 0);
expect('restore all: the list is gone', c.get('mayhem', 'mysub', 'hidden') == null);

exit(fails ? 1 : 0);
