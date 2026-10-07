// Decodes the test vpn:// keys with the LuCI module (node 18+).
//   node tests/vpnkey.js
'use strict';

const fs = require('fs');
const path = require('path');

const root = path.join(__dirname, '..');
const src = fs.readFileSync(path.join(root, 'luci-app-mayhem/htdocs/luci-static/resources/mayhem/vpnkey.js'), 'utf8');
const body = src.replace(/^'require [^']*';$/mg, '');
global._ = (s) => s;

const mod = new Function('baseclass', body)({ extend: (o) => o });
const key = fs.readFileSync(path.join(__dirname, 'awg/key.txt'), 'utf8');
const apikey = fs.readFileSync(path.join(__dirname, 'awg/apikey.txt'), 'utf8');
const want = fs.readFileSync(path.join(__dirname, 'awg/client.conf'), 'utf8')
	.replace('$PRIMARY_DNS', '1.1.1.1').replace('$SECONDARY_DNS', '1.0.0.1');

(async () => {
	let failed = 0;

	if (!mod.isKey(key) || mod.isKey('[Interface]')) {
		console.log('FAIL isKey');
		failed++;
	}

	const conf = await mod.decode(key);

	if (conf !== want) {
		console.log('FAIL decoded config differs:\n' + conf);
		failed++;
	}

	try {
		await mod.decode(apikey);
		console.log('FAIL subscription key accepted');
		failed++;
	}
	catch (e) {
		if (!/app/.test(e.message)) {
			console.log('FAIL wrong error: ' + e.message);
			failed++;
		}
	}

	console.log(failed ? 'vpnkey: failed' : 'vpnkey: ok');
	process.exit(failed ? 1 : 0);
})();
