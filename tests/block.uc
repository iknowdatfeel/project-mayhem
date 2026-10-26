// Block sections: spelled-out domains are refused by dnsmasq ("local="), xray
// keeps only what dnsmasq cannot match. Prints one line per failed
// expectation; no output means all is well.
//   ucode tests/block.uc
'use strict';

import { build } from 'mayhem.build';

const SS = 'ss://2022-blake3-aes-128-gcm:AAECAwQFBgcICQoLDA0ODw%3D%3D@nl.example:8443#NL';

function model(mode, block, extra) {
	const m = {
		settings: { mode: mode, interface: [ 'br-lan' ] },
		dns: { domestic: [ '77.88.8.8' ], remote: [ 'https://1.1.1.1/dns-query' ] },
		sections: [
			{ '.name': 'main', type: 'proxy', link: [ SS ], domain: [ 'youtube.com' ] },
			{ '.name': 'ads', type: 'block', domain: block }
		],
		geo: {
			sources: [ { name: 's', kind: 'geosite', enabled: true,
				index: { categories: { ads: 72620, mixed: 3 }, copied: [ 'ads', 'mixed' ] } } ],
			domains: {
				's:ads': [ 'domain:ads.example', 'full:pixel.example', 'domain:Track.Example' ],
				's:mixed': [ 'domain:m.example', 'keyword:banner' ]
			},
			cidrs: {}
		},
		runtime: { now: 1 }
	};

	for (let k in extra ?? {})
		m.dns[k] = extra[k];

	return m;
}

function rules_text(res) {
	return sprintf('%J', res.xray.routing.rules);
}

let fails = 0;

function expect(what, cond, res) {
	if (!cond) {
		fails++;
		print(`FAIL ${what}\n  dnsmasq: ${substr(res.dnsmasq, 0, 300)}\n  rules: ${substr(rules_text(res), 0, 600)}\n`);
	}
}

// Global: the category and plain domains go to dnsmasq, a keyword stays in xray.
let r = build(model('global', [ 'geosite:ads', 'domain:my.example', 'keyword:promo' ]));
expect('global: category refused by dnsmasq', match(r.dnsmasq, /local=\/[^\n]*ads\.example/) && index(r.dnsmasq, 'track.example') >= 0, r);
expect('global: plain domain refused by dnsmasq', index(r.dnsmasq, 'my.example') >= 0, r);
expect('global: no category in xray', index(rules_text(r), 'ext:s.dat:ads') < 0, r);
expect('global: keyword still in xray', index(rules_text(r), 'keyword:promo') >= 0, r);
expect('global: no heavy-category warning', !length(filter(r.status.warnings, (w) => index(w, 'a lot of memory') >= 0)), r);

// A category with keyword rules: spelled out for dnsmasq and kept in xray.
r = build(model('global', [ 'geosite:mixed' ]));
expect('mixed category: domains in dnsmasq', index(r.dnsmasq, 'm.example') >= 0, r);
expect('mixed category: kept in xray', index(rules_text(r), 'ext:s.dat:mixed') >= 0, r);

// DNS not redirected to dnsmasq: devices may ask other servers, xray blocks.
r = build(model('global', [ 'geosite:ads' ], { hijack: '0' }));
expect('no DNS redirect: nothing in dnsmasq', index(r.dnsmasq, 'local=') < 0, r);
expect('no DNS redirect: category in xray', index(rules_text(r), 'ext:s.dat:ads') >= 0, r);

// By lists: blocked names no longer make dnsmasq send every query to xray.
r = build(model('lists', [ 'geosite:ads' ]));
expect('lists: split DNS stays on with a big block category', r.state.dns?.split == true, r);
expect('lists: blocked names are not sent to xray', index(r.dns_xray ?? '', 'ads.example') < 0, r);

exit(fails ? 1 : 0);
