// Entries of a list option as the generator reads them: spaces, commas and
// new lines separate them, but a regexp keeps its commas ({1,3}); a DNS
// server with a port that is not one is refused.
// Prints one line per failed expectation; no output means all is well.
//   ucode tests/entries.uc
'use strict';

import { entries, dns_server } from 'mayhem.rules';

let fails = 0;

function expect(what, cond, got) {
	if (!cond) {
		fails++;
		print(`FAIL ${what}: ${sprintf('%J', got)}\n`);
	}
}

let e = entries([ 'a.com, b.com', 'regexp:^ex[0-9]{1,3}\\.com$', 'c.com regexp:^x{2,}$' ]);
expect('plain entries and regexps', length(e) == 5 && e[0] == 'a.com' && e[1] == 'b.com' &&
	e[2] == 'regexp:^ex[0-9]{1,3}\\.com$' && e[3] == 'c.com' && e[4] == 'regexp:^x{2,}$', e);

e = entries('d.com,regexp:^y{1,2}$');
expect('a regexp after a comma keeps its commas', length(e) == 2 && e[1] == 'regexp:^y{1,2}$', e);

e = entries('#comment\ne.com');
expect('comments are left out', length(e) == 1 && e[0] == 'e.com', e);

expect('a DNS port too big', dns_server('1.1.1.1:99999').error != null, dns_server('1.1.1.1:99999'));
expect('a DNS port zero', dns_server('1.1.1.1:0').error != null, dns_server('1.1.1.1:0'));
expect('a DoH port too big', dns_server('https://dns.example:70000/dns-query').error != null, dns_server('https://dns.example:70000/dns-query'));
expect('a good DNS port', dns_server('1.1.1.1:5353').port == 5353, dns_server('1.1.1.1:5353'));
expect('a good DoH server', dns_server('https://1.1.1.1/dns-query').address == 'https://1.1.1.1/dns-query', dns_server('https://1.1.1.1/dns-query'));

exit(fails ? 1 : 0);
