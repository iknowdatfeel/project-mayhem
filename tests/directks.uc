// Direct DNS and kernel bypass survive Xray; known shared IPs keep using VPN.
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
		expect(`${what}: Direct DNS bypasses Xray`, index(r.dnsmasq, 'server=/direct.parent.test/exact.test/77.88.8.8\n') >= 0);
		expect(`${what}: second domestic resolver`, index(r.dnsmasq, 'server=/direct.parent.test/exact.test/77.88.8.1\n') >= 0);
		expect(`${what}: full is not a suffix`, index(r.dnsmasq, 'server=/*.exact.test/127.0.0.1#12753\n') >= 0 && index(r.dnsmasq, 'nftset=/*.exact.test/4#inet#mayhem#oth_d4') >= 0);
		expect(`${what}: shared IPs keep VPN routing`, index(r.nft, 'ip daddr @dir_d4 ip daddr != @oth_d4 counter return') >= 0 && index(r.nft, 'ip6 daddr @dir_d6 ip6 daddr != @oth_d6 counter return') >= 0);
		expect(`${what}: router Direct bypass`, index(r.nft, 'ip daddr @dir_d4 ip daddr != @oth_d4 return') >= 0);
		expect(`${what}: unsupported pattern is explicit`, length(filter(r.status.warnings, (w) => index(w, 'Direct rules need running Xray') >= 0)) > 0);
		writefile(`${ARGV[0]}/${mode}-${kernel}.nft`, r.nft);
		writefile(`${ARGV[0]}/${mode}-${kernel}.json`, sprintf('%J', r.xray));
		model.runtime.dnsmasq_nftset = false;
		const no = build(model);
		expect(`${what}: no nftset still bypasses DNS`, index(no.dnsmasq, 'server=/direct.parent.test/exact.test/77.88.8.8') >= 0);
		expect(`${what}: missing nftset is explicit`, length(filter(no.status.warnings, (w) => index(w, 'Direct domains need dnsmasq-full') >= 0)) > 0);
	}
}
exit(fails ? 1 : 0);
