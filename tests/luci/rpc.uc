// Calls one method of the rpcd plugin.
//   rpc.uc PLUGIN METHOD JSON-ARGS
'use strict';

const plugin = loadfile(ARGV[0])();
const m = plugin['luci.mayhem'][ARGV[1]];

print(sprintf('%J\n', m.call({ args: json(ARGV[2] ?? 'null') ?? {} })));
