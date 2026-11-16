// geosite:/geoip: lines of a rule list (list_file, list_url) are skipped with
// a warning of their own and wait for no geo update; the other lines work.
// Prints one line per failed expectation; no output means all is well.
//   ucode tests/listgeo.uc
'use strict';

import { build } from 'mayhem.build';

const SS = 'ss://2022-blake3-aes-128-gcm:AAECAwQFBgcICQoLDA0ODw%3D%3D@nl.example:8443#NL';
const LIST = '/etc/mayhem/my.lst';

const lists = {};
lists[LIST] = 'listed.test\ngeosite:youtube\ngeoip:telegram\n10.20.30.0/24\n';

const r = build({
	settings: { mode: 'lists', interface: [ 'br-lan' ] },
	dns: { domestic: [ '77.88.8.8' ], remote: [ 'https://1.1.1.1/dns-query' ] },
	sections: [ { '.name': 'main', type: 'proxy', link: [ SS ], list_file: [ LIST ] } ],
	lists: lists,
	geo: { sources: [ { name: 's', kind: 'geosite', enabled: true, index: null } ], domains: {}, cidrs: {} },
	runtime: { now: 1 }
});

let fails = 0;

function expect(what, cond, text) {
	if (!cond) {
		fails++;
		print(`FAIL ${what}\n${text ?? ''}\n`);
	}
}

const w = r.status.warnings;
const rules = sprintf('%J', r.xray.routing.rules);

expect('one warning for the geo lines of the list',
	length(filter(w, (x) => x == `section "main": list ${LIST}: geosite:/geoip: entries work only in the section's own rules, skipped`)) == 1, sprintf('%J', w));
expect('no "not downloaded yet" for them', !length(filter(w, (x) => index(x, 'not downloaded yet') >= 0)), sprintf('%J', w));
expect('not lines that are not rules', !length(filter(w, (x) => index(x, 'lines that are not rules') >= 0)), sprintf('%J', w));
expect('nothing waits for a geo update', !length(keys(r.state.geo_pending ?? {})), sprintf('%J', r.state.geo_pending));
expect('the other lines of the list work', index(rules, 'listed.test') >= 0 && index(r.nft, '10.20.30.0/24') >= 0, rules);

exit(fails ? 1 : 0);
