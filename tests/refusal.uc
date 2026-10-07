// Writes one xray config per server address into OUT_DIR, each with a VLESS
// or Trojan outbound without TLS, and prints "<file> <0|1> <address>" where 1
// means refused_by_xray() expects xray to refuse it. tests/run.sh checks the
// guess against `xray run -test`.
//   ucode tests/refusal.uc OUT_DIR
'use strict';

import { writefile } from 'fs';
import { refused_by_xray } from 'mayhem.links';

const dir = ARGV[0];
const addrs = [
	'1.2.3.4', '100.128.0.1', '8.8.8.8', '2001:db8::1', '2a00:1450::1', 'example.com', 'sub.example.com', 'lan.example.org',
	'10.0.0.1', '100.64.0.1', '172.20.0.1', '192.168.1.5', '198.18.0.1', '198.19.255.1', '224.0.0.1', '250.1.1.1',
	'fd00::1', 'fe80::1', '::1', 'router', 'Router.LAN', 'nas.local', 'box.internal', 'a.home.arpa', 'x.localdomain', 'y.test.'
];

let n = 0;

for (let a in addrs) {
	for (let proto in [ 'vless', 'trojan' ]) {
		const ob = {
			tag: 'x', protocol: proto,
			settings: proto == 'vless'
				? { address: a, port: 443, id: '11111111-2222-3333-4444-555555555555', encryption: 'none' }
				: { address: a, port: 443, password: 'pw' },
			streamSettings: { network: 'ws', security: 'none' }
		};
		const file = `${dir}/${++n}.json`;

		writefile(file, sprintf('%J', {
			inbounds: [ { listen: '127.0.0.1', port: 10999, protocol: 'socks' } ],
			outbounds: [ ob ]
		}));
		print(`${file} ${refused_by_xray(ob) ? 1 : 0} ${proto}://${a}\n`);
	}
}
