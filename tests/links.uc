// Link parser cases: [link, expected protocol or "error"].
'use strict';

import { parse_link, refused_by_xray } from 'mayhem.links';

const UUID = '11111111-2222-3333-4444-555555555555';
const cases = [
	[ `vless://${UUID}@example.com:443?type=tcp&security=reality&sni=www.microsoft.com&fp=chrome&pbk=SbVKOEMjK0sIlbwg4akyBg5mL5KZwwB-ed4eEE7YnRc&sid=6ba85179e30d4fc2&flow=xtls-rprx-vision#NL`, 'vless' ],
	[ `vless://${UUID}@[2001:db8::1]:8443?type=xhttp&security=tls&sni=a.example&path=%2Fxh&mode=packet-up#x`, 'vless' ],
	[ `vless://${UUID}@h.example:443?type=ws&security=tls&path=%2Fws%3Fed%3D2048&host=h.example#ws`, 'vless' ],
	[ `vless://${UUID}@h.example:443?type=grpc&security=tls&serviceName=grpc&mode=multi#g`, 'vless' ],
	[ `vless://${UUID}@h.example:80?type=tcp&headerType=http&host=a.com,b.com&path=%2F#h`, 'vless' ],
	[ 'vmess://' + b64enc(`{"v":"2","ps":"vm","add":"1.2.3.4","port":"443","id":"${UUID}","aid":"0","net":"ws","type":"none","host":"h.example","path":"/ws","tls":"tls","sni":"h.example"}`), 'vmess' ],
	[ 'trojan://p%40ss@t.example:443?type=grpc&serviceName=svc&sni=t.example#tr', 'trojan' ],
	[ 'ss://' + b64enc('chacha20-ietf-poly1305:secret') + '@5.6.7.8:8388#ss1', 'shadowsocks' ],
	[ 'ss://2022-blake3-aes-128-gcm:AAECAwQFBgcICQoLDA0ODw%3D%3D@5.6.7.8:8388#ss22', 'shadowsocks' ],
	[ 'ss://' + b64enc('aes-256-gcm:pw@9.8.7.6:1234') + '#legacy', 'shadowsocks' ],
	[ 'socks://' + b64enc('u:p') + '@9.9.9.9:1080#s', 'socks' ],
	[ 'socks5://u:p@9.9.9.9:1080', 'socks' ],
	[ 'https://u:p@proxy.example:443', 'http' ],
	[ 'hy2://pass@hy.example:443?sni=hy.example&obfs=salamander&obfs-password=xyz#hy', 'hysteria' ],
	[ 'hysteria2://user:pass@hy.example:443/?sni=hy.example#hy', 'hysteria' ],
	[ 'wireguard://cGFzc3Bhc3NwYXNzcGFzc3Bhc3NwYXNzcGFzc3Bhc3M%3D@wg.example:51820?publickey=Zm9vYmFyZm9vYmFyZm9vYmFyZm9vYmFyZm9vYmFyMTI%3D&address=10.0.0.2%2F32&reserved=1,2,3#wg', 'wireguard' ],
	[ `vless://${UUID}@h:443?type=h2`, 'error' ],
	[ `vless://${UUID}@h:443?security=reality`, 'error' ],
	[ 'ss://YWVzLTI1Ni1nY206cHc@h.example:443?plugin=v2ray-plugin', 'error' ],
	[ `vless://${UUID}@h.example:443,2000-3000?security=tls`, 'error' ],
	[ 'foo://bar', 'error' ],
	[ '', 'error' ]
];

let failed = 0;

for (let c in cases) {
	let got;

	try {
		got = parse_link(c[0]).outbound.protocol;
	}
	catch (e) {
		got = 'error';
	}

	if (got != c[1]) {
		failed++;
		print(`FAIL ${substr(c[0], 0, 60)}: expected ${c[1]}, got ${got}\n`);
	}
}

// Servers xray 26 refuses to start with: [link, refused?]
const refused = [
	[ `vless://${UUID}@185.132.132.239:9443?security=none&type=ws&path=%2Fupload#b`, true ],
	[ `vless://${UUID}@vpn.example.com:80?type=tcp#b`, true ],
	[ `vless://${UUID}@[2001:db8::1]:80?type=ws#b`, true ],
	[ `vless://${UUID}@192.168.1.10:80?security=none&type=ws#lan`, false ],
	[ `vless://${UUID}@nas.lan:80?type=ws#lan`, false ],
	[ `vless://${UUID}@1.2.3.4:443?type=ws&security=tls&sni=a.example#tls`, false ],
	[ `vless://${UUID}@1.2.3.4:443?type=tcp&security=reality&sni=a.example&pbk=SbVKOEMjK0sIlbwg4akyBg5mL5KZwwB-ed4eEE7YnRc&sid=ab#r`, false ],
	[ `vless://${UUID}@1.2.3.4:443?type=tcp&encryption=mlkem768x25519plus.native.0rtt.abc#enc`, false ],
	[ 'trojan://pw@1.2.3.4:80?security=none&type=ws#t', true ],
	[ 'trojan://pw@1.2.3.4:443?sni=a.example#t', false ],
	[ 'ss://YWVzLTI1Ni1nY206cHc@1.2.3.4:8388#ss', false ]
];

for (let c in refused) {
	const got = refused_by_xray(parse_link(c[0]).outbound) != null;

	if (got != c[1]) {
		failed++;
		print(`FAIL refused_by_xray ${substr(c[0], 0, 70)}: expected ${c[1]}, got ${got}\n`);
	}
}

print(`links: ${length(cases) + length(refused) - failed}/${length(cases) + length(refused)} ok\n`);
exit(failed ? 1 : 0);
