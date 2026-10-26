// Mux on VLESS servers. Prints one line per failed expectation; no output
// means all is well.
//   ucode tests/mux.uc
// A Vision server breaks Mux connections that carry TCP, so with Vision only
// UDP goes through XUDP (concurrency -1), in the flat form and in the "vnext"
// form of JSON subscriptions alike. XHTTP multiplexes on its own: no Mux.
'use strict';

import { build } from 'mayhem.build';

const U = '11111111-2222-3333-4444-555555555555';
const PBK = 'SbVKOEMjK0sIlbwg4akyBg5mL5KZwwB-ed4eEE7YnRc';

const vnext = (host, flow, ss) => ({
	protocol: 'vless',
	settings: { vnext: [ { address: host, port: 443, users: [ { id: U, encryption: 'none', flow: flow } ] } ] },
	streamSettings: ss
});

const model = {
	settings: { mode: 'lists', interface: [ 'br-lan' ], mux: '1' },
	dns: { remote: [ 'https://1.1.1.1/dns-query' ] },
	sections: [ { '.name': 'main', type: 'proxy', select: 'auto', subscription: [ 'sub' ], domain: [ 'youtube.com' ] } ],
	subscriptions: {
		sub: {
			nodes: [
				{ name: 'flat vision', link: `vless://${U}@flat.example:443?type=tcp&security=reality&sni=a.example&pbk=${PBK}&sid=ab&flow=xtls-rprx-vision#flat` },
				{ name: 'vnext vision', outbound: vnext('vnext.example', 'xtls-rprx-vision',
					{ network: 'tcp', security: 'reality', realitySettings: { serverName: 'a.example', publicKey: PBK, shortId: 'ab' } }) },
				{ name: 'vnext ws', outbound: vnext('ws.example', null,
					{ network: 'ws', security: 'tls', tlsSettings: { serverName: 'ws.example' }, wsSettings: { path: '/' } }) },
				{ name: 'xhttp', outbound: vnext('xh.example', null,
					{ network: 'xhttp', security: 'tls', tlsSettings: { serverName: 'xh.example' }, xhttpSettings: { path: '/x' } }) }
			]
		}
	},
	runtime: { now: 1 }
};

const res = build(model);
const mux = {};

for (let ob in res.xray.outbounds) {
	const s = ob.settings ?? {};
	const host = length(s.vnext ?? []) ? s.vnext[0].address : s.address;

	if (host)
		mux[host] = ob.mux;
}

let fails = 0;

function expect(what, cond) {
	if (!cond) {
		fails++;
		print(`FAIL ${what}: ${sprintf('%J', mux)}\n`);
	}
}

expect('flat Vision: UDP only', mux['flat.example']?.concurrency == -1);
expect('vnext Vision: UDP only', mux['vnext.example']?.concurrency == -1);
expect('vnext without Vision: Mux for TCP too', mux['ws.example']?.concurrency > 0);
expect('XHTTP: no Mux', mux['xh.example'] == null);

exit(fails ? 1 : 0);
