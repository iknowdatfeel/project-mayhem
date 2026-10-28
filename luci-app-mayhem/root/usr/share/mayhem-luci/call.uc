// Mayhem: runs one method of the rpcd plugin in a process of its own.
//   call.uc METHOD JSON-ARGS
//
// rpcd runs every plugin call in its one process: a call that waits for the
// network (a URL test, the external address, a subscription download) would
// hold every other call of LuCI and ubus meanwhile, and the browser gives up
// on them ("XHR request aborted"). Such calls run here instead, and rpcd
// answers when this process is done (see run_apart() in the plugin).

'use strict';

import * as fs from 'fs';

const PLUGIN = getenv('MAYHEM_RPC_PLUGIN') ?? '/usr/share/rpcd/ucode/luci.mayhem';
// The plugin compiled once (it is 4 000 lines with its modules: compiling
// it took most of every such call on a small router), kept in RAM under
// the times of its sources: a new plugin, module or ucode makes a new one.
const CACHE = getenv('MAYHEM_RPC_CACHE') ?? '/tmp/mayhem-luci';
const MODULES = getenv('MAYHEM_RPC_MODULES') ?? '/usr/share/ucode/mayhem';

function q(s) {
	return "'" + replace(`${s}`, /'/g, "'\\''") + "'";
}

function compiled() {
	const ucode = fs.readlink('/proc/self/exe') ?? 'ucode';
	let sig = fs.stat(PLUGIN)?.mtime ?? 0;

	for (let f in [ ...(fs.glob(`${MODULES}/*.uc`) ?? []), ucode ])
		sig = max(sig, fs.stat(f)?.mtime ?? 0);

	const file = `${CACHE}/plugin.${sig}.ucc`;

	if (!fs.access(file)) {
		const tmp = `${file}.${split(fs.readfile('/proc/self/stat') ?? '', ' ')[0]}`;
		const lib = replace(MODULES, /\/[^\/]*$/, '/*.uc');

		fs.mkdir(CACHE, 0700);

		// the ones of older sources
		for (let f in fs.glob(`${CACHE}/plugin.*.ucc`) ?? [])
			fs.unlink(f);

		if (system(`${q(ucode)} -L ${q(lib)} -c -o ${q(tmp)} ${q(PLUGIN)} >/dev/null 2>&1`) != 0 || !fs.rename(tmp, file)) {
			fs.unlink(tmp);
			return null;
		}
	}

	try {
		const p = loadfile(file)();

		if (type(p?.['luci.mayhem']) == 'object')
			return p;
	}
	catch (e) {
	}

	fs.unlink(file);

	return null;
}

const plugin = compiled() ?? loadfile(PLUGIN)();
const m = plugin['luci.mayhem'][ARGV[0]];
let args;

try {
	args = json(ARGV[1] ?? 'null') ?? {};
}
catch (e) {
	args = {};
}

let res;

try {
	res = m ? m.call({ args: args }) : { error: 'unknown method' };
}
catch (e) {
	res = { error: e.message };
}

print(sprintf('%J\n', type(res) == 'object' ? res : {}));
