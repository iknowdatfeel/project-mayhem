// Mayhem: runs one method of the rpcd plugin in a process of its own.
//   call.uc METHOD JSON-ARGS
//   call.uc METHOD @FILE      the arguments in FILE, removed once read
//
// rpcd runs every plugin call in its one process: a call that waits for the
// network (a URL test, the external address, a subscription download) would
// hold every other call of LuCI and ubus meanwhile, and the browser gives up
// on them ("XHR request aborted"). Such calls run here instead, and rpcd
// answers when this process is done (see run_apart() in the plugin).

'use strict';

import * as fs from 'fs';
import { q } from 'mayhem.util';

const PLUGIN = getenv('MAYHEM_RPC_PLUGIN') ?? '/usr/share/rpcd/ucode/luci.mayhem';
// The plugin compiled once (it is 4 000 lines with its modules: compiling
// it took most of every such call on a small router), kept in RAM under a
// hash of its sources: name, size, time and inode of the plugin, of every
// module and of ucode. Any of them replaced makes a new one, also by a file
// with an older time (a package put back to an earlier version).
const CACHE = getenv('MAYHEM_RPC_CACHE') ?? '/tmp/mayhem-luci';
const MODULES = getenv('MAYHEM_RPC_MODULES') ?? '/usr/share/ucode/mayhem';

// FNV-1a, 32 bits
function fnv(s) {
	let h = 0x811c9dc5;

	for (let i = 0; i < length(s); i++)
		h = ((h ^ ord(s, i)) * 0x01000193) & 0xffffffff;

	return sprintf('%08x', h);
}

function compiled() {
	const ucode = fs.readlink('/proc/self/exe') ?? 'ucode';
	let src = '';

	for (let f in [ PLUGIN, ...sort(fs.glob(`${MODULES}/*.uc`) ?? []), ucode ]) {
		const st = fs.stat(f);

		src += `${f}:${st?.size}:${st?.mtime}:${st?.inode}\n`;
	}

	const sig = fnv(src);

	const file = `${CACHE}/plugin.${sig}.ucc`;

	if (!fs.access(file)) {
		fs.mkdir(CACHE, 0700);

		const pid = split(fs.readfile('/proc/self/stat') ?? '', ' ')[0] || int(clock(true)[1]);
		const tmp = `${file}.${pid}.${int(clock(true)[1])}`;
		const lib = replace(MODULES, /\/[^\/]*$/, '/*.uc');

		// the ones of older sources
		for (let f in fs.glob(`${CACHE}/plugin.*.ucc`) ?? [])
			if (f != file)
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
let args, text = ARGV[1] ?? 'null';

// The plugin passes the arguments in a file (run_apart()): read at once
// and gone, whatever is in it.
if (substr(text, 0, 1) == '@') {
	const file = substr(text, 1);

	text = fs.readfile(file) ?? 'null';
	fs.unlink(file);
}

try {
	args = json(text) ?? {};
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
