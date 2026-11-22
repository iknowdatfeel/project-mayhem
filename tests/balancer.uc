// What `xray api bi` prints, as parse_balancer_info of mayhem.check reads
// it: fixtures saved from the xray version Mayhem installs (const.sh). A
// new xray that prints otherwise fails here first. Prints one line per
// failed expectation; no output means all is well.
//   ucode tests/balancer.uc FIXTURES
'use strict';

import { readfile } from 'fs';
import { parse_balancer_info } from 'mayhem.check';

let fails = 0;

function expect(what, cond, got) {
	if (!cond) {
		print(`${what}: ${sprintf('%J', got)}\n`);
		fails++;
	}
}

let b = parse_balancer_info(readfile(`${ARGV[0]}/xray-bi.txt`));

expect('a pinned server', b.override == 'n-pool-b' && join(' ', b.selects) == 'n-pool-a n-pool-b', b);

b = parse_balancer_info(readfile(`${ARGV[0]}/xray-bi-none.txt`));
expect('nothing pinned', b.override == null && join(' ', b.selects) == 'n-pool-a n-pool-b', b);

b = parse_balancer_info('');
expect('no answer', b.override == null && length(b.selects) == 0, b);

exit(fails ? 1 : 0);
