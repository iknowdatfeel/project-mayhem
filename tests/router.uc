// "Router through the proxy" (settings.router_traffic): the router's new TCP
// connections go to xray by the same rules, xray's own sockets are marked and
// left alone, the router's UDP is not touched. Writes the nftables rules of
// the global case to ARGV[0] (for nft -c) and prints one line per failed
// expectation; no output means all is well.
//   ucode tests/router.uc OUT.nft
'use strict';

import { writefile } from 'fs';
import { build } from 'mayhem.build';
import { XRAY_OUT_MARK, FAKEDNS_POOL } from 'mayhem.const';

const SS = 'ss://2022-blake3-aes-128-gcm:AAECAwQFBgcICQoLDA0ODw%3D%3D@nl.example:8443#NL';

function model(mode, on) {
	return {
		settings: { mode: mode, interface: [ 'br-lan' ], router_traffic: on ? '1' : '0', block_quic: '1' },
		dns: { domestic: [ '77.88.8.8' ], remote: [ 'https://1.1.1.1/dns-query' ] },
		sections: [
			{ '.name': 'main', type: 'proxy', link: [ SS ], domain: [ 'youtube.com' ], ip: [ '91.108.4.0/22' ] },
			{ '.name': 'ru', type: 'exclusion', ip: [ '45.0.0.0/24' ] },
			{ '.name': 'ads', type: 'block', ip: [ '46.0.0.0/24' ] }
		],
		runtime: { now: 1 }
	};
}

let fails = 0;

function expect(what, cond, text) {
	if (!cond) {
		fails++;
		print(`FAIL ${what}\n${text ?? ''}\n`);
	}
}

const output = (nft) => {
	const i = index(nft, 'chain output {');

	return i < 0 ? '' : split(substr(nft, i), '\n\t}')[0];
};
const marked = (res) => filter(res.xray.outbounds, (o) => o.streamSettings?.sockopt?.mark == XRAY_OUT_MARK);
const dialing = (res) => filter(res.xray.outbounds, (o) => o.protocol != 'blackhole' && o.protocol != 'loopback');

let r = build(model('global', true));
let out = output(r.nft);
writefile(ARGV[0], r.nft);

expect('global: xray sockets leave the chain output', index(out, sprintf('meta mark & 0x%x == 0x%x return', XRAY_OUT_MARK, XRAY_OUT_MARK)) >= 0, out);
expect('global: only TCP of the router', index(out, 'meta l4proto != tcp return') >= 0, out);
expect('global: replies to incoming connections left alone', index(out, 'ct direction reply return') >= 0, out);
expect('global: exclusions stay direct', index(out, 'ip daddr @direct4 return') >= 0, out);
expect('global: the rest is marked for xray', match(out, /meta nfproto ipv4 meta mark set meta mark \| 0x2000000/) != null, out);
expect('global: the marked traffic is taken from lo', match(r.nft, /iifname "lo" meta mark & 0x2000000 == 0x2000000 meta nfproto ipv4 meta l4proto \{ tcp, udp \} tproxy/) != null, r.nft);
expect('global: every xray outbound that dials is marked', length(marked(r)) == length(dialing(r)) && length(marked(r)) > 0,
	sprintf('%J', map(r.xray.outbounds, (o) => [ o.tag, o.streamSettings?.sockopt?.mark ])));

// Blocked addresses and QUIC are refused in the kernel at once (TCP reset,
// "port unreachable"), never held in xray; QUIC after the direct ones.
const pre = (nft) => split(substr(nft, index(nft, 'chain prerouting {')), '\n\t}')[0];
const REF = 'meta mark set meta mark | 0x8000000 counter return';
const p = pre(r.nft);

expect('blocked addresses refused', index(p, `ip daddr @block4 ${REF}`) >= 0, p);
expect('QUIC refused before xray, after the direct ones', index(p, `meta l4proto udp th dport 443 ${REF}`) > index(p, 'ip daddr @direct4 counter return') &&
	index(p, `meta l4proto udp th dport 443 ${REF}`) < index(p, 'meta nfproto ipv4 meta l4proto { tcp, udp } meta mark set meta mark | 0x2000000'), p);
expect('UDP refused with port unreachable', index(r.nft, 'meta l4proto udp counter reject with icmpx type port-unreachable') >= 0, r.nft);

r = build(model('lists', true));
expect('lists: QUIC refused only for what would reach xray', index(pre(r.nft), `ip daddr @px4 meta l4proto udp th dport 443 ${REF}`) >= 0, pre(r.nft));
out = output(r.nft);
expect('lists: only what the rules send to a proxy', index(out, 'ip daddr @px4 meta mark set') >= 0 && match(out, /meta nfproto ipv4 meta mark set/) == null, out);

r = build(model('global', false));
expect('off: no xray marks', !length(marked(r)), null);
expect('off: no router rules', index(output(r.nft), 'ct direction reply') < 0, output(r.nft));

// By lists, fake addresses: xray dialling one it does not know must not come
// back to xray through the chain output, and is refused before that.
r = build(model('lists', false));
expect('lists, off: every xray outbound that dials is marked', length(marked(r)) == length(dialing(r)) && length(marked(r)) > 0,
	sprintf('%J', map(r.xray.outbounds, (o) => [ o.tag, o.streamSettings?.sockopt?.mark ])));
expect('lists, off: xray sockets leave the chain output', index(output(r.nft), sprintf('meta mark & 0x%x == 0x%x return', XRAY_OUT_MARK, XRAY_OUT_MARK)) >= 0, output(r.nft));
expect('lists: an unknown fake address is refused',
	length(filter(r.xray.routing.rules, (x) => x.outboundTag == 'block' && x.ip?.[0] == FAKEDNS_POOL && x.inboundTag?.[0] == 'tproxy-in')) == 1,
	sprintf('%J', r.xray.routing.rules));

exit(fails ? 1 : 0);
