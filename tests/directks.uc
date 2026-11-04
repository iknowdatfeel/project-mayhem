// Direct rules use the independent DNS policy even with KillSwitch enabled.
'use strict';
import { writefile } from 'fs';
import { build } from 'mayhem.build';

let fails = 0;
function expect(what, cond) {
	if (!cond) { print(`FAIL ${what}\n`); fails++; }
}
for (let mode in [ 'global', 'lists' ]) {
	for (let kernel in [ false, true ]) {
		const model = {
			settings: { mode: mode, killswitch: '1', router_traffic: '1', default_section: kernel ? 'tun' : 'main' },
			dns: { domestic: [ '77.88.8.8', '77.88.8.1' ], remote: [ 'https://1.1.1.1/dns-query' ] },
			sections: [
				{ '.name': 'main', type: 'proxy', link: 'trojan://pw@proxy.test:443#Proxy', domain: [ 'parent.test', 'keyword:proxy' ] },
				{ '.name': 'direct', type: 'exclusion', domain: [ 'direct.parent.test', 'full:exact.test', 'keyword:bank' ], ip: [ '5.0.0.0/8', '2a00:1::/32' ], ports: [ '123' ] },
				{ '.name': 'tun', type: 'interface', interface: 'tun0' }
			],
			runtime: { ipv6: true, dnsmasq_nftset: true, ifaces: { tun0: { device: 'tun0', up: true, v6: true } } }
		};
		const r = build(model), what = `${mode}, kernel ${kernel}`;
		expect(`${what}: builds`, r.ok);
		const policy = sprintf('%J', r.dns_policy);
		expect(`${what}: Direct rules exported to native DNS`, index(policy, 'domain:direct.parent.test') >= 0 && index(policy, 'full:exact.test') >= 0 && index(policy, 'keyword:bank') >= 0);
		expect(`${what}: IPv4 and IPv6 exported`, index(policy, '5.0.0.0/8') >= 0 && index(policy, '2a00:1::/32') >= 0);
		expect(`${what}: no Direct pattern in Xray`, index(sprintf('%J', r.xray.routing.rules), 'keyword:bank') < 0);
		expect(`${what}: LAN Direct mark bypass`, index(r.nft, 'meta mark & 0x40000000 != 0 return') >= 0);
		expect(`${what}: DNS cache does not outlive policy`, index(r.dnsmasq, 'cache-size=0') >= 0);
		writefile(`${ARGV[0]}/${mode}-${kernel}.nft`, r.nft);
		writefile(`${ARGV[0]}/${mode}-${kernel}.json`, sprintf('%J', r.xray));
		model.runtime.dnsmasq_nftset = false;
		const no = build(model);
		expect(`${what}: native DNS works without dnsmasq nftset`, index(sprintf('%J', no.dns_policy), 'keyword:bank') >= 0);

	}
}
exit(fails ? 1 : 0);
