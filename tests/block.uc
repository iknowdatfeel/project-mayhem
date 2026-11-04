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

// Block domains, including category references and patterns, belong to the
// native DNS policy only. DNS refusal must not prevent learning their IPs.
for (let mode in [ 'global', 'lists' ]) {
	let r = build(model(mode, [ 'geosite:ads', 'domain:my.example', 'keyword:promo' ]));
	const native = sprintf('%J', r.dns_policy);
	expect(`${mode}: category exported to DNS policy`, index(native, 'ext:s.dat:ads') >= 0, r);
	expect(`${mode}: plain domain exported to DNS policy`, index(native, 'domain:my.example') >= 0, r);
	expect(`${mode}: keyword exported to DNS policy`, index(native, 'keyword:promo') >= 0, r);
	expect(`${mode}: no category or keyword in Xray`, index(rules_text(r), 'ext:s.dat:ads') < 0 && index(rules_text(r), 'keyword:promo') < 0, r);
	expect(`${mode}: DNS obtains real Block addresses`, index(r.dnsmasq, 'local=') < 0, r);
	expect(`${mode}: no heavy Xray category warning`, !length(filter(r.status.warnings, (w) => index(w, 'a lot of memory') >= 0)), r);
	r = build(model(mode, [ 'geosite:mixed' ]));
	expect(`${mode}: mixed category stays native`, index(sprintf('%J', r.dns_policy), 'ext:s.dat:mixed') >= 0 && index(rules_text(r), 'ext:s.dat:mixed') < 0, r);
	r = build(model(mode, [ 'geosite:ads' ], { hijack: '0' }));
	expect(`${mode}: no silent Xray fallback without DNS hijack`, index(rules_text(r), 'ext:s.dat:ads') < 0, r);
}
exit(fails ? 1 : 0);
