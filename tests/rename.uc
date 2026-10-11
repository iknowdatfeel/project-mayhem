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

expect('an empty name is refused', call('rename_server', { section: 'pool', tag: 'n-pool-1', name: ' ' }).error != null);
expect('an unknown server is refused', call('rename_server', { section: 'pool', tag: 'n-pool-9', name: 'x' }).error != null);

exit(fails ? 1 : 0);
