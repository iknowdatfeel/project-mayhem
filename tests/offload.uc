// Diagnostics with flow offloading in the firewall: a warning in the group
// "kernel", none without it. Needs MAYHEM_UCI_DIR with a writable copy of a
// config. Prints what went wrong; no output means all is well.
//   ucode tests/offload.uc PLUGIN
'use strict';

import * as fs from 'fs';

const dir = getenv('MAYHEM_UCI_DIR');
const plugin = loadfile(ARGV[0])()['luci.mayhem'];
let fails = 0;

function offload_check() {
	const r = plugin.diagnose.call({ args: { part: 'local' } });
	const list = type(r) == 'array' ? r : (r?.checks ?? []);

	return filter(list, (c) => c.name == 'Flow offloading')[0];
}

fs.writefile(`${dir}/firewall`, "config defaults\n\toption input 'REJECT'\n\toption flow_offloading '1'\n");
const on = offload_check();

if (!on || on.group != 'kernel' || on.status != 'warn' || index(on.detail, 'keep their old path') < 0) {
	print(`flow offloading on: ${sprintf('%J', on)}\n`);
	fails++;
}

fs.writefile(`${dir}/firewall`, "config defaults\n\toption input 'REJECT'\n\toption flow_offloading_hw '1'\n");

if (!offload_check()) {
	print('hardware flow offloading on: no warning\n');
	fails++;
}

fs.writefile(`${dir}/firewall`, "config defaults\n\toption input 'REJECT'\n");

if (offload_check()) {
	print('flow offloading off: a warning all the same\n');
	fails++;
}

exit(fails ? 1 : 0);
