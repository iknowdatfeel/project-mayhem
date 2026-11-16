// A server xray refused (runtime.refused, from refused.json) is left out of
// the build with a warning; the others keep their tags. Prints one line per
// failed expectation; no output means all is well.
//   ucode tests/refused.uc
'use strict';

import { build } from 'mayhem.build';

const A = 'ss://2022-blake3-aes-128-gcm:AAECAwQFBgcICQoLDA0ODw%3D%3D@1.2.3.4:8443#A';
const B = 'ss://2022-blake3-aes-128-gcm:AAECAwQFBgcICQoLDA0ODw%3D%3D@1.2.3.5:8443#B';

function model(links, refused) {
	return {
		settings: { mode: 'lists', interface: [ 'br-lan' ] },
		dns: { domestic: [ '77.88.8.8' ], remote: [ 'https://1.1.1.1/dns-query' ] },
		sections: [ { '.name': 'main', type: 'proxy', link: links, domain: [ 'youtube.com' ] } ],
		runtime: { now: 1, refused: refused }
	};
}

let fails = 0;

function expect(what, cond, text) {
	if (!cond) {
		fails++;
		print(`FAIL ${what}\n${text ?? ''}\n`);
	}
}

const nodes = (r) => filter(r.xray.outbounds, (o) => match(o.tag ?? '', /^n-main-/));
const tag_of = (r, host) => filter(nodes(r), (o) => index(sprintf('%J', o), host) >= 0)[0]?.tag;

let r = build(model([ A, B ], {}));
const ta = tag_of(r, '1.2.3.4'), tb = tag_of(r, '1.2.3.5');

expect('two servers without refusals', length(nodes(r)) == 2 && ta && tb, sprintf('%J', nodes(r)));
expect('two servers: a balancer', r.state.sections.main?.mode == 'auto', sprintf('%J', r.state.sections.main));

const one = {};
one[tb] = { name: 'B', error: 'unknown protocol', at: 1 };
r = build(model([ A, B ], one));

expect('the refused server is left out', length(nodes(r)) == 1 && tag_of(r, '1.2.3.4') == ta && !tag_of(r, '1.2.3.5'),
	sprintf('%J', nodes(r)));
expect('the section is decided without it (single)', r.state.sections.main?.mode == 'single', sprintf('%J', r.state.sections.main));
expect('the warning names the server and the error',
	index(r.status.warnings ?? [], 'server "B": xray refused it (unknown protocol); skipped') >= 0, sprintf("%J", r.status.warnings));

const both = {};
both[ta] = { name: 'A', error: 'x', at: 1 };
both[tb] = { name: 'B', error: 'y', at: 1 };
r = build(model([ A, B ], both));
expect('every server refused: the section is skipped', !length(nodes(r)) && !r.state.sections.main, sprintf('%J', r.state.sections));

exit(fails ? 1 : 0);
