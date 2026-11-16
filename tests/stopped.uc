// The real rpcd methods after "stop" and after "start" (tests/stopped.sh
// sets up the stand-ins). Prints what went wrong; no output means all is well.
//   ucode tests/stopped.uc PLUGIN
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

const log = () => fs.readfile(`${stub}/init.log`) ?? '';

// Whether the init script got "reload" within 3 s.
function reloaded() {
	for (let i = 0; i < 30; i++) {
		if (index(log(), 'init reload') >= 0)
			return true;

		sleep(100);
	}

	return false;
}

call('action', { name: 'stop' });
expect('stop leaves a mark in the run directory', fs.access(`${run}/stopped`));

expect('rename after stop', call('rename_section', { name: 'video', new_name: 'films' }).ok === true);
expect('rename after stop: no reload', !reloaded(), log());

call('action', { name: 'start' });
expect('start takes the mark away', !fs.access(`${run}/stopped`));

expect('rename after start', call('rename_section', { name: 'films', new_name: 'video' }).ok === true);
expect('rename after start: reload', reloaded(), log());

exit(fails ? 1 : 0);
