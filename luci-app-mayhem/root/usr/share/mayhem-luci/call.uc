// Mayhem: runs one method of the rpcd plugin in a process of its own.
//   call.uc METHOD JSON-ARGS
//
// rpcd runs every plugin call in its one process: a call that waits for the
// network (a URL test, the external address, a subscription download) would
// hold every other call of LuCI and ubus meanwhile, and the browser gives up
// on them ("XHR request aborted"). Such calls run here instead, and rpcd
// answers when this process is done (see run_apart() in the plugin).

'use strict';

const PLUGIN = getenv('MAYHEM_RPC_PLUGIN') ?? '/usr/share/rpcd/ucode/luci.mayhem';
const plugin = loadfile(PLUGIN)();
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
