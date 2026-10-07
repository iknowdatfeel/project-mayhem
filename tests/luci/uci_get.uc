// Prints a UCI config the way rpcd's "uci get" returns it.
//   uci_get.uc CONFDIR CONFIG
'use strict';

const c = require('uci').cursor(ARGV[0]);

c.load(ARGV[1]);
print(sprintf('%J\n', c.get_all(ARGV[1]) ?? {}));
