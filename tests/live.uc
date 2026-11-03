// What a new server list changes in the generated config. Prints one line
// per failed expectation; no output means all is well.
//   ucode tests/live.uc
// Servers keep their tags whatever their order and names, and the restart key
// (everything but the servers) stays the same unless something only a restart
// can change did change. Server hosts are not in it: a host under a new
// domain waits for the nightly catch-up.
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
	expect(`${mode}: new rules are applied without a restart`, key(r1) == key(build(model(mode, [ `${A}#NL`, `${B}#DE` ], [ 'youtube.com', 'other.com' ]))));
	expect(`${mode}: the fallback server has a tag of its own`,
		length(filter(r1.xray.outbounds, (o) => o.tag == 'f-main')) == 1 &&
		r1.xray.routing.balancers[0].fallbackTag == 'f-main');
}

// In "everything through proxy" mode server names must not reach the remote
// DNS through the proxy itself: their domains go to the domestic DNS.
const g = build(model('global', [ `${A}#NL`, `${B}#DE` ]));

expect('global: server domain goes to the domestic DNS',
	index(g.xray.dns.servers[0].domains, 'domain:provider.example') >= 0 && g.xray.dns.servers[0].address == '77.88.8.8');
// A new domain goes in at the nightly catch-up (mayhem_dns_catchup), not by
// restarting xray at once: some subscriptions bring one every hour, and every
// restart cut all connections of the network.
const g2 = build(model('global', [ `${A}#NL`, `${B}#DE`, `${D}#Other` ]));

expect('global: a server under a new domain needs no restart', key(g) == key(g2));
expect('global: its domain is in the DNS config for the next start',
	index(g2.xray.dns.servers[0].domains, 'domain:other.example') >= 0);
expect('lists: a server under a new domain needs no restart',
	key(build(model('lists', [ `${A}#NL`, `${B}#DE` ]))) == key(build(model('lists', [ `${A}#NL`, `${B}#DE`, `${D}#Other` ]))));

// One server is also behind a balancer, so it can be replaced in place.
const one = build(model('global', [ `${A}#NL` ]));

expect('one server: routed through a balancer', length(filter(one.xray.routing.rules, (r) => r.balancerTag == 'bal-main')) > 0);
expect('one server: replaced by another without a restart', key(one) == key(build(model('global', [ `${B}#DE` ]))));

// VPN endpoints bypass before blocking/section rules, with real DNS answers.
const ep = build(model('global', [ `${A}#NL`, `${E}#IP` ]));
const ip_rule = filter(ep.xray.routing.rules, (r) => index(r.ip ?? [], '1.2.3.4') >= 0)[0];
expect('server IP bypasses through direct', ip_rule?.outboundTag == 'direct');
expect('server names populate the endpoint set', index(ep.dnsmasq, 'nftset=/nl1.provider.example/4#inet#mayhem#endpoint_d4') >= 0);
expect('server names use real DNS', index(ep.dnsmasq, 'server=/nl1.provider.example/77.88.8.8') >= 0);
expect('kernel endpoint bypass precedes blocking', index(ep.nft, 'ip daddr @endpoint4 return') < index(ep.nft, 'ip daddr @block4'));
const off = model('global', [ `${E}#IP` ]);
off.settings.exclude_local = '0';
expect('endpoint bypass follows the local-network option', !length(filter(build(off).xray.routing.rules, (r) => index(r.ip ?? [], '1.2.3.4') >= 0)));

const next_choice = model('global', [ `${A}#NL` ]);
next_choice.runtime.flow_path = one.state.flow_path;
next_choice.settings.reconnect_epoch = '1';
const reset = build(next_choice);
expect('an explicit choice invalidates old kernel and proxy flows', reset.state.flow_path.generation != one.state.flow_path.generation);
expect('an explicit choice restarts Xray', key(reset) != key(one));
next_choice.runtime.flow_path = reset.state.flow_path;
expect('a routine reload keeps the flow generation', build(next_choice).state.flow_path.generation == reset.state.flow_path.generation);

// Local edits keep the provider identity and survive a fresh provider response.
const sub = model('global', []);
sub.sections[0].subscription = [ 'mysub' ];
sub.subscriptions = { mysub: { nodes: [ { name: 'Provider NL', link: `${A}#Original` } ] } };
sub.aliases = { mysub: { 'Provider NL': 'My edited server' } };
sub.server_overrides = { mysub: { 'Provider NL': sprintf('%J', { tag: 'My edited server', protocol: 'shadowsocks',
	settings: { address: 'edited.example', port: 443, method: 'aes-128-gcm', password: 'fixture' } }) } };
let edited = build(sub).state.sections.main.nodes[0];
expect('subscription edit applies endpoint and keeps identity', edited.address == 'edited.example' && edited.orig == 'Provider NL' && edited.name == 'My edited server');
sub.subscriptions.mysub.nodes[0].link = `${B}#Provider-update`;
edited = build(sub).state.sections.main.nodes[0];
expect('provider update keeps the local edit', edited.address == 'edited.example' && edited.link == sub.server_overrides.mysub['Provider NL']);

exit(fails ? 1 : 0);
