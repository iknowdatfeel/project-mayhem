// What a new server list changes in the generated config. Prints one line
// per failed expectation; no output means all is well.
//   ucode tests/live.uc
// Servers keep their tags whatever their order and names, and the restart key
// (everything but the servers) stays the same unless something only a restart
// can change did change: rules, or in "everything through proxy" mode a server
// host under a domain the DNS config does not have yet.
'use strict';

import { build } from 'mayhem.build';

const SS = 'ss://2022-blake3-aes-128-gcm:AAECAwQFBgcICQoLDA0ODw%3D%3D';
const A = `${SS}@nl1.provider.example:8443`;
const B = `${SS}@de1.provider.example:8443`;
const C = `${SS}@fi1.provider.example:8443`;
const D = `${SS}@vpn.other.example:8443`;
const E = `${SS}@1.2.3.4:8443`;

function model(mode, links, domains) {
	return {
		settings: { mode: mode, interface: [ 'br-lan' ] },
		dns: { domestic: [ '77.88.8.8' ], remote: [ 'https://1.1.1.1/dns-query' ] },
		sections: [ { '.name': 'main', type: 'proxy', select: 'auto', link: links, domain: domains ?? [ 'youtube.com' ] } ],
		runtime: { now: 1 }
	};
}

function tags(res) {
	const out = {};

	for (let n in res.state.sections.main.nodes)
		out[n.address] = n.tag;

	return out;
}

const key = (res) => sprintf('%J', res.key);
let fails = 0;

function expect(what, cond) {
	if (!cond) {
		print(`${what}\n`);
		fails++;
	}
}

for (let mode in [ 'lists', 'global' ]) {
	const r1 = build(model(mode, [ `${A}#NL`, `${B}#DE` ]));
	const r2 = build(model(mode, [ `${B}#DE 2`, `${A}#NL (new)`, `${C}#FI` ]));
	const t1 = tags(r1), t2 = tags(r2);

	expect(`${mode}: tags follow the server, not its place or name`,
		t1['nl1.provider.example'] == t2['nl1.provider.example'] && t1['de1.provider.example'] == t2['de1.provider.example']);
	expect(`${mode}: a new server of the same provider needs no restart`, key(r1) == key(r2));
	expect(`${mode}: an address as a server needs no restart`, key(r1) == key(build(model(mode, [ `${A}#NL`, `${B}#DE`, `${E}#IP` ]))));
	expect(`${mode}: new rules need a restart`, key(r1) != key(build(model(mode, [ `${A}#NL`, `${B}#DE` ], [ 'youtube.com', 'other.com' ]))));
	expect(`${mode}: the fallback server has a tag of its own`,
		length(filter(r1.xray.outbounds, (o) => o.tag == 'f-main')) == 1 &&
		r1.xray.routing.balancers[0].fallbackTag == 'f-main');
}

// In "everything through proxy" mode server names must not reach the remote
// DNS through the proxy itself: their domains go to the domestic DNS.
const g = build(model('global', [ `${A}#NL`, `${B}#DE` ]));

expect('global: server domain goes to the domestic DNS',
	index(g.xray.dns.servers[0].domains, 'domain:provider.example') >= 0 && g.xray.dns.servers[0].address == '77.88.8.8');
expect('global: a server under a new domain needs a restart',
	key(g) != key(build(model('global', [ `${A}#NL`, `${B}#DE`, `${D}#Other` ]))));
expect('lists: a server under a new domain needs no restart',
	key(build(model('lists', [ `${A}#NL`, `${B}#DE` ]))) == key(build(model('lists', [ `${A}#NL`, `${B}#DE`, `${D}#Other` ]))));

// One server is also behind a balancer, so it can be replaced in place.
const one = build(model('global', [ `${A}#NL` ]));

expect('one server: routed through a balancer', length(filter(one.xray.routing.rules, (r) => r.balancerTag == 'bal-main')) > 0);
expect('one server: replaced by another without a restart', key(one) == key(build(model('global', [ `${B}#DE` ]))));

exit(fails ? 1 : 0);
