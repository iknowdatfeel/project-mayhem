// Backup of the UCI config through the rpcd backend: export with and without
// connections, import back. Needs MAYHEM_UCI_DIR with a writable copy of a
// config. Prints what went wrong; no output means all is well.
//   ucode tests/backup.uc PLUGIN
'use strict';

import { readfile } from 'fs';

const plugin = loadfile(ARGV[0])()['luci.mayhem'];
const call = (m, args) => plugin[m].call({ args: args });
const path = `${getenv('MAYHEM_UCI_DIR')}/mayhem`;
const before = readfile(path);
const lines = (t) => sort(filter(split(t, '\n'), (l) => trim(l) != ''));
let fails = 0;

function expect(what, cond) {
	if (!cond) {
		print(`${what}\n`);
		fails++;
	}
}

const full = call('backup_export', { connections: true });
const bare = call('backup_export', { connections: false });
const text = sprintf('%J', bare);

expect('full backup has the subscription', index(sprintf('%J', full), '"subscription"') >= 0);
expect('backup without connections has no subscription, link or hwid',
	index(text, 'mysub') < 0 && index(text, '"link"') < 0 && index(text, '"hwid"') < 0);

expect('full backup restores', call('backup_import', { backup: full }).ok === true);
expect('full backup gives the same config', sprintf('%J', lines(readfile(path))) == sprintf('%J', lines(before)));

expect('backup without connections restores', call('backup_import', { backup: bare }).kept_connections === true);
expect('connections of the router are kept', sprintf('%J', lines(readfile(path))) == sprintf('%J', lines(before)));

expect('not a backup is refused', call('backup_import', { backup: { sections: [] } }).error != null);
expect('unknown section type is refused',
	call('backup_import', { backup: { mayhem_backup: 1, sections: [ { '.type': 'network', '.name': 'x' } ] } }).error != null);
expect('a failed import changes nothing', sprintf('%J', lines(readfile(path))) == sprintf('%J', lines(before)));

exit(fails ? 1 : 0);
