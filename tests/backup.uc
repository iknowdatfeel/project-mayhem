// Backup of the UCI config through the rpcd backend: export with and without
// connections, import back. Needs MAYHEM_UCI_DIR with a writable copy of a
// config. Prints what went wrong; no output means all is well.
//   ucode tests/backup.uc PLUGIN
'use strict';

import { readfile } from 'fs';
import { cursor } from 'uci';

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

// Files of a backup only where its sections name a local list, never in
// the directories of Mayhem's own files (hold/nft is loaded by nft at boot).
const evil = { ...full, files: { '/etc/mayhem/hold/nft': 'flush ruleset\n', '/etc/mayhem/other.lst': 'x.com\n' } };
let r = call('backup_import', { backup: evil });
expect(`files nobody lists are not written: ${sprintf('%J', r)}`, r.ok === true && r.files == 0 && r.skipped == 2);
const listed = { ...full, sections: [ ...full.sections, { '.type': 'section', '.name': 'evil', type: 'block', list_file: [ '/etc/mayhem/hold/nft' ] } ],
	files: { '/etc/mayhem/hold/nft': 'flush ruleset\n' } };
r = call('backup_import', { backup: listed });
expect(`hold/ is never written: ${sprintf('%J', r)}`, r.ok === true && r.files == 0 && r.skipped == 1);
expect('full backup restores again', call('backup_import', { backup: full }).ok === true);

expect('not a backup is refused', call('backup_import', { backup: { sections: [] } }).error != null);
expect('unknown section type is refused',
	call('backup_import', { backup: { mayhem_backup: 1, sections: [ { '.type': 'network', '.name': 'x' } ] } }).error != null);
expect('a failed import changes nothing', sprintf('%J', lines(readfile(path))) == sprintf('%J', lines(before)));

// A tunnel's own section (its name, kept off the server list) is not part of
// a backup: importing one, or resetting the settings, leaves it alone.
const tunnel = () => {
	const c = cursor(getenv('MAYHEM_UCI_DIR'));

	c.load('mayhem');

	return c.get('mayhem', 'wg0') == 'tunnel' && c.get('mayhem', 'wg0', 'label') == 'Home VPN' &&
		c.get('mayhem', 'wg0', 'server') == '0';
};
const tc = cursor(getenv('MAYHEM_UCI_DIR'));

tc.load('mayhem');
tc.set('mayhem', 'wg0', 'tunnel');
tc.set('mayhem', 'wg0', 'label', 'Home VPN');
tc.set('mayhem', 'wg0', 'server', '0');
tc.commit('mayhem');

expect('a tunnel section is in place', tunnel());
expect('full backup restores next to a tunnel', call('backup_import', { backup: full }).ok === true);
expect('the tunnel section stays after a full backup', tunnel());
expect('backup without connections restores next to a tunnel', call('backup_import', { backup: bare }).kept_connections === true);
expect('the tunnel section stays after a backup without connections', tunnel());

if (getenv('MAYHEM_DEFAULTS')) {
	expect('reset keeping connections', call('reset_config', { connections: true }).ok === true);
	expect('the tunnel section stays after a reset keeping connections', tunnel());
	expect('reset without connections', call('reset_config', { connections: false }).ok === true);
	expect('the tunnel section stays after a reset without connections', tunnel());
}
else
	expect('MAYHEM_DEFAULTS is set for the reset', false);

exit(fails ? 1 : 0);
