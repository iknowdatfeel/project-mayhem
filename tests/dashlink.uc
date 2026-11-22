// The dashboard's answer, asked every few seconds, carries no server keys;
// server_link gives one key when the editor needs it. Needs MAYHEM_RUN_DIR.
// Prints what went wrong; no output means all is well.
//   ucode tests/dashlink.uc PLUGIN
'use strict';

import * as fs from 'fs';

const run = getenv('MAYHEM_RUN_DIR');
const KEY = 'ss://2022-blake3-aes-128-gcm:c2VjcmV0@1.2.3.4:8443#Secret';

fs.writefile(`${run}/nodes.json`, sprintf('%J', {
	generated: 1, default_section: 'pool',
	sections: { pool: { type: 'proxy', mode: 'single', selected: 'n-pool-a',
		nodes: [ { tag: 'n-pool-a', name: 'Secret', protocol: 'shadowsocks', address: '1.2.3.4', port: 8443, link: KEY, usec: 'mysub' } ] } }
}));

const plugin = loadfile(ARGV[0])()['luci.mayhem'];
const call = (m, args) => plugin[m].call({ args: args });
let fails = 0;

function expect(what, cond) {
	if (!cond) {
		print(`${what}\n`);
		fails++;
	}
}

const d = sprintf('%J', call('dashboard', {}));

expect(`the dashboard answers with the server: ${substr(d, 0, 300)}`, index(d, 'n-pool-a') >= 0);
expect('no key in the dashboard\'s answer', index(d, 'c2VjcmV0') < 0 && index(d, '"link"') < 0);

const k = call('server_link', { section: 'pool', tag: 'n-pool-a' });

expect(`server_link gives the key and its subscription: ${sprintf('%J', k)}`, k.link == KEY && k.usec == 'mysub');
expect('server_link of an unknown server', call('server_link', { section: 'pool', tag: 'n-x' }).error != null);

// Asked again with nothing changed (nodes.json kept parsed in rpcd): the
// same answer; a new nodes.json (a rename, as runstate writes it) is read.
const strip = (x) => { delete x.now; return sprintf('%J', x); };
const d1 = strip(call('dashboard', {}));
const d2 = strip(call('dashboard', {}));

expect('the dashboard answers the same when asked again', d1 == d2);
fs.writefile(`${run}/nodes.json.tmp`, replace(fs.readfile(`${run}/nodes.json`), '"Secret"', '"Renamed"'));
fs.rename(`${run}/nodes.json.tmp`, `${run}/nodes.json`);
expect('a new nodes.json is read at once', index(sprintf('%J', call('dashboard', {})), 'Renamed') >= 0);

exit(fails ? 1 : 0);
