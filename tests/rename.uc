// Renaming servers through the rpcd backend: a key (the name in the key), a
// vmess key (its "ps"), a subscription server (an alias), a tunnel (its
// name); the pinned server follows. Needs MAYHEM_UCI_DIR with a writable
// mayhem config and MAYHEM_RUN_DIR. Prints what went wrong.
//   ucode tests/rename.uc PLUGIN
'use strict';

import { writefile, mkdir } from 'fs';
import { parse_link } from 'mayhem.links';

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

const vless = 'vless://af4505da-4332-4ffd-99fd-50013e4e8f34@de.example:443?security=tls&sni=de.example#Old%20DE';
const vmess = 'vmess://' + b64enc(sprintf('%J', { v: '2', ps: 'Old VM', add: 'vm.example', port: '443', id: 'af4505da-4332-4ffd-99fd-50013e4e8f34', net: 'tcp' }));

let c = cursor();

c.set('mayhem', 'pool', 'pool');
c.set('mayhem', 'pool', 'link', [ vless, vmess ]);
c.set('mayhem', 'pool', 'override', 'Old DE');
c.set('mayhem', 'mysub', 'subscription');
c.set('mayhem', 'mysub', 'url', 'http://example.invalid/sub');
c.commit('mayhem');

mkdir(run);
writefile(`${run}/nodes.json`, sprintf('%J', { sections: { pool: { type: 'proxy', nodes: [
	{ tag: 'n-pool-1', name: 'Old DE', source: 'link' },
	{ tag: 'n-pool-2', name: 'Provider NL', orig: 'Provider NL', source: 'mysub' },
	{ tag: 'n-pool-3', name: 'awg_de', source: 'interface', iface: 'awg_de' } ] } } }));

let r = call('rename_server', { section: 'pool', tag: 'n-pool-1', name: 'Германия' });
c = cursor();
const links = c.get('mayhem', 'pool', 'link');

expect(`key: ${r.error}`, r.ok === true);
expect('key: the name is in the key', parse_link(links[0]).name == 'Германия' && index(links[0], 'de.example:443') > 0);
expect('key: the pinned server follows', c.get('mayhem', 'pool', 'override') == 'Германия');

r = call('rename_server', { link: vmess, name: 'Новый VM' });
c = cursor();
expect(`vmess key: ${r.error}`, r.ok === true && parse_link(c.get('mayhem', 'pool', 'link')[1]).name == 'Новый VM');

r = call('rename_server', { section: 'pool', tag: 'n-pool-2', name: 'Нидерланды' });
c = cursor();
expect(`subscription server: ${r.error}`, r.ok === true && index(c.get('mayhem', 'mysub', 'alias') ?? [], 'Provider NL\tНидерланды') >= 0);

r = call('rename_server', { section: 'pool', tag: 'n-pool-3', name: 'Amnezia DE' });
c = cursor();
expect(`tunnel: ${r.error}`, r.ok === true && c.get('mayhem', 'awg_de', 'label') == 'Amnezia DE');

// A renamed key keeps its place in the chain of the server list.
c = cursor();
c.set('mayhem', 'pool', 'chain', [ 'Германия', 'mysub\tProvider NL', '@mysub' ]);
c.commit('mayhem');
r = call('rename_server', { link: c.get('mayhem', 'pool', 'link')[0], name: 'DE' });
c = cursor();
expect(`key in the chain: ${r.error}`, r.ok === true && c.get('mayhem', 'pool', 'chain')[0] == 'DE');

// A subscription renamed: the chain, a section that names it, its servers
// downloaded before and the state of its downloads go along.
const subs = getenv('MAYHEM_SUBS_DIR');

mkdir(subs);
writefile(`${subs}/mysub.json`, sprintf('%J', { name: 'mysub', url: 'http://example.invalid/sub', nodes: [ { name: 'Provider NL', link: vless } ] }));
writefile(`${run}/subs-state.json`, sprintf('%J', { mysub: { updated: 1 } }));
r = call('rename_subscription', { name: 'mysub', new_name: 'newsub' });
c = cursor();

const chain = c.get('mayhem', 'pool', 'chain');
const cache = json(require('fs').readfile(`${subs}/newsub.json`) ?? 'null');
const state = json(require('fs').readfile(`${run}/subs-state.json`) ?? 'null');

expect(`subscription: ${r.error}`, r.ok === true && c.get('mayhem', 'newsub') == 'subscription' && c.get('mayhem', 'mysub') == null);
expect(`subscription: the chain follows (${chain})`, chain[1] == 'newsub\tProvider NL' && chain[2] == '@newsub');
expect('subscription: the section naming it follows', index(c.get('mayhem', 'main', 'subscription') ?? [], 'newsub') >= 0);
expect('subscription: its servers go along', cache?.name == 'newsub' && length(cache?.nodes) == 1 && !require('fs').access(`${subs}/mysub.json`));
expect('subscription: its state goes along', state?.newsub?.updated == 1 && state?.mysub == null);
expect('a taken name is refused', call('rename_subscription', { name: 'newsub', new_name: 'main' }).error != null);
expect('a bad name is refused', call('rename_subscription', { name: 'newsub', new_name: 'a b' }).error != null);

expect('an empty name is refused', call('rename_server', { section: 'pool', tag: 'n-pool-1', name: ' ' }).error != null);
expect('an unknown server is refused', call('rename_server', { section: 'pool', tag: 'n-pool-9', name: 'x' }).error != null);

exit(fails ? 1 : 0);
