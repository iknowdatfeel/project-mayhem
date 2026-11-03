// Several DNS servers: one after another with standard Xray timeouts; all at once
// only when asked and only where the provider's DNS stays out of the race.
// Prints one line per failed expectation; no output means all is well.
//   ucode tests/dnsrow.uc
'use strict';

import { build } from 'mayhem.build';

const SS = 'ss://2022-blake3-aes-128-gcm:AAECAwQFBgcICQoLDA0ODw%3D%3D@nl.example:8443#NL';
const R1 = 'https://1.1.1.1/dns-query', R2 = 'https://8.8.8.8/dns-query';

function model(mode, remote, dns) {
	const m = {
		settings: { mode: mode, interface: [ 'br-lan' ] },
		dns: { domestic: [ '77.88.8.8' ], remote: remote },
		sections: [ { '.name': 'main', type: 'proxy', link: [ SS ], domain: [ 'youtube.com' ] } ],
		runtime: { now: 1 }
	};

	for (let k in dns ?? {})
		m.dns[k] = dns[k];

	return m;
}

let fails = 0;

function expect(what, cond, res) {
	if (!cond) {
		fails++;
		print(`FAIL ${what}: ${sprintf('%J', res.xray.dns)} idle ${res.xray.policy.levels?.['1']?.connIdle}\n`);
	}
}

// The user requested Xray defaults for UDP and internal DNS, including
// resolver timeouts. Omitting overrides follows the installed core version.
for (let remotes in [ [ R1 ], [ R1, R2 ], [ R1, R2, 'https://9.9.9.9/dns-query' ] ]) {
	const r = build(model('global', remotes));
	expect('fallback by default', !r.xray.dns.enableParallelQuery, r);
	expect('DNS uses core timeouts', !length(filter(r.xray.dns.servers, (x) => x.timeoutMs != null)), r);
	expect('session timeouts use core defaults', r.xray.policy.levels == null, r);
}

let r;
// Parallel when asked, in global mode without FakeDNS.
r = build(model('global', [ R1, R2 ], { parallel: '1' }));
expect('parallel when asked', r.xray.dns.enableParallelQuery == true, r);

// By lists too when asked, with a warning: the provider's DNS gets the
// names in the same race.
r = build(model('lists', [ R1, R2 ], { parallel: '1' }));
expect('parallel by lists when asked', r.xray.dns.enableParallelQuery == true, r);
expect('a warning about the provider', length(filter(r.status.warnings, (w) => index(w, 'parallel DNS') >= 0)) == 1, r);
r = build(model('global', [ R1, R2 ], { parallel: '1' }));
expect('no warning in global mode', !length(filter(r.status.warnings, (w) => index(w, 'parallel DNS') >= 0)), r);

exit(fails ? 1 : 0);
