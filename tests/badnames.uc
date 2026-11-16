// Names of geo data that are not domain names (a line break, "/", a space)
// never reach dnsmasq's files: skipped with one warning per section and
// category. Prints one line per failed expectation; no output means all is
// well.
//   ucode tests/badnames.uc
'use strict';

import { build } from 'mayhem.build';

const SS = 'ss://2022-blake3-aes-128-gcm:AAECAwQFBgcICQoLDA0ODw%3D%3D@nl.example:8443#NL';
const BAD = [ 'domain:good.example', 'domain:evil.example\nserver=/x/1.2.3.4', 'domain:a/b.example', 'full:sp ace.example' ];

function model(mode, sections, killswitch) {
	return {
		settings: { mode: mode, interface: [ 'br-lan' ], killswitch: killswitch ? '1' : '0' },
		dns: { domestic: [ '77.88.8.8' ], remote: [ 'https://1.1.1.1/dns-query' ] },
		sections: sections,
		geo: {
			sources: [ { name: 's', kind: 'geosite', enabled: true,
				index: { categories: { bad: 4 }, copied: [ 'bad' ] } } ],
			domains: { 's:bad': BAD },
			cidrs: {}
		},
		runtime: { now: 1, dnsmasq_nftset: true }
	};
}

let fails = 0;

function expect(what, cond, text) {
	if (!cond) {
		fails++;
		print(`FAIL ${what}\n${text ?? ''}\n`);
	}
}

const clean = (t) => index(t, 'evil') < 0 && index(t, 'a/b.example') < 0 && index(t, 'sp ace') < 0 && index(t, '1.2.3.4') < 0;
const told = (r, sec) => filter(r.status.warnings, (w) => match(w, regexp(`^section "${sec}": 3 names of .*bad.* are not valid domain names, skipped$`)));

// A block section: local= lines.
let r = build(model('global', [
	{ '.name': 'main', type: 'proxy', link: [ SS ], domain: [ 'youtube.com' ] },
	{ '.name': 'ads', type: 'block', domain: [ 'geosite:bad' ] }
]));
expect('block: the good name is refused by dnsmasq', index(r.dnsmasq, 'good.example') >= 0, r.dnsmasq);
expect('block: no bad name in dnsmasq.conf', clean(r.dnsmasq), r.dnsmasq);
expect('block: one warning', length(told(r, 'ads')) == 1, sprintf('%J', r.status.warnings));

// A proxy section by lists: server= lines of the names xray resolves.
r = build(model('lists', [
	{ '.name': 'main', type: 'proxy', link: [ SS ], domain: [ 'geosite:bad' ] }
]));
expect('lists: no bad name in the servers xray resolves', clean(r.dns_xray ?? ''), r.dns_xray);
expect('lists: no bad name in dnsmasq.conf', clean(r.dnsmasq), r.dnsmasq);
expect('lists: one warning', length(told(r, 'main')) == 1, sprintf('%J', r.status.warnings));

// Direct with the kill switch: server= lines to the domestic DNS.
r = build(model('lists', [
	{ '.name': 'main', type: 'proxy', link: [ SS ], domain: [ 'youtube.com' ] },
	{ '.name': 'ru', type: 'exclusion', domain: [ 'geosite:bad' ] }
], true));
expect('direct: no bad name in dnsmasq.conf', clean(r.dnsmasq), r.dnsmasq);
expect('direct: one warning', length(told(r, 'ru')) == 1, sprintf('%J', r.status.warnings));

exit(fails ? 1 : 0);
