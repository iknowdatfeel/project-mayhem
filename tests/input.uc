// What reaches the router itself (chain input): xray's interception port
// refuses what is addressed to the router, the local ports of sections take
// only lo and the interfaces of Mayhem. Writes the nftables rules with local
// ports to ARGV[0] (for nft -c) and prints one line per failed expectation;
// no output means all is well.
//   ucode tests/input.uc OUT.nft
'use strict';

import { writefile } from 'fs';
import { build } from 'mayhem.build';
import { TPROXY_PORT } from 'mayhem.const';

const SS = 'ss://2022-blake3-aes-128-gcm:AAECAwQFBgcICQoLDA0ODw%3D%3D@nl.example:8443#NL';

function model(mode, ports) {
	const sections = [
		{ '.name': 'main', type: 'proxy', link: [ SS ], domain: [ 'youtube.com' ] }
	];

	if (ports) {
		sections[0].local_port = '1080';
		push(sections, { '.name': 'video', type: 'proxy', link: [ SS ], domain: [ 'example.org' ], local_port: '8118' });
	}

	return {
		settings: { mode: mode, interface: [ 'br-lan', 'wlan1' ] },
		dns: { domestic: [ '77.88.8.8' ], remote: [ 'https://1.1.1.1/dns-query' ] },
		sections: sections,
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

const input = (nft) => {
	const i = index(nft, 'chain input {');

	return i < 0 ? '' : split(substr(nft, i), '\n\t}')[0];
};
const TP = `meta l4proto { tcp, udp } th dport ${TPROXY_PORT} fib daddr type local counter reject`;

for (let mode in [ 'lists', 'global' ]) {
	let r = build(model(mode, true));
	let c = input(r.nft);

	if (mode == 'lists')
		writefile(ARGV[0], r.nft);

	expect(`${mode}: chain input hooks input`, index(c, 'type filter hook input priority filter; policy accept;') >= 0, r.nft);
	expect(`${mode}: the interception port refuses what is addressed to the router`, index(c, TP) >= 0, c);
	expect(`${mode}: the local ports take only lo and the interfaces of Mayhem`,
		index(c, 'iifname != "lo" iifname != @ifaces meta l4proto { tcp, udp } th dport { 1080, 8118 } counter drop') >= 0, c);
	expect(`${mode}: the interfaces of Mayhem`, index(r.nft, 'elements = { "br-lan", "wlan1" }') >= 0, r.nft);

	r = build(model(mode, false));
	c = input(r.nft);
	expect(`${mode}, no local ports: the interception port still refuses`, index(c, TP) >= 0, c);
	expect(`${mode}, no local ports: no drop rule`, index(c, 'drop') < 0, c);
}

exit(fails ? 1 : 0);
