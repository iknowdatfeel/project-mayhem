// WireGuard/AmneziaWG .conf parsing.
//   awg.uc tests/awg/client.conf
'use strict';

import { readfile } from 'fs';
import { parse_conf, is_amnezia, uci_sections } from 'mayhem.awg';

let failed = 0, total = 0;

function check(what, got, want) {
	total++;

	const g = sprintf('%J', got), w = sprintf('%J', want);

	if (g != w) {
		failed++;
		print(`FAIL ${what}: expected ${w}, got ${g}\n`);
	}
}

const conf = parse_conf(readfile(ARGV[0]));
const awg = uci_sections(conf, 'amneziawg');

check('amnezia detected', is_amnezia(conf), true);
check('addresses', awg.iface.addresses, [ '10.8.1.2/32', 'fd00:8::2/128' ]);
check('obfuscation', [ awg.iface.awg_jc, awg.iface.awg_s2, awg.iface.awg_h4, awg.iface.awg_random_trailers ], [ '4', '120', '349374436', '1' ]);
check('special junk packet', substr(awg.iface.awg_i1, 0, 5), '<b 0x');
check('peer', awg.peers[0], {
	public_key: 'Zm9vYmFyZm9vYmFyZm9vYmFyZm9vYmFyZm9vYmFyMTI=',
	allowed_ips: [ '0.0.0.0/0', '::/0' ],
	route_allowed_ips: '0',
	description: 'Mayhem',
	preshared_key: 'c2VjcmV0c2VjcmV0c2VjcmV0c2VjcmV0c2VjcmV0MTI=',
	endpoint_host: '203.0.113.10',
	endpoint_port: '51820',
	persistent_keepalive: '25'
});
check('tunnel has IPv6', awg.v6, true);

const wg = uci_sections(parse_conf('[Interface]\nPrivateKey = k\nAddress = 10.0.0.2/32\n[Peer]\nPublicKey = p\nEndpoint = [2001:db8::1]:51820\n'), 'wireguard');

check('plain WireGuard', [ wg.iface.proto, wg.iface.awg_jc, wg.peers[0].endpoint_host, wg.peers[0].endpoint_port, wg.v6 ],
	[ 'wireguard', null, '2001:db8::1', '51820', false ]);

let err = null;

try {
	parse_conf('[Interface]\nAddress = 10.0.0.2/32\n');
}
catch (e) {
	err = e.message;
}

check('no private key', err, 'no [Interface] with a PrivateKey');

print(`awg: ${total - failed}/${total} ok\n`);
exit(failed ? 1 : 0);
