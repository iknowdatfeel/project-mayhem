// Decodes the test vpn:// keys with the LuCI module (node 18+).
//   node tests/vpnkey.js
'use strict';

const fs = require('fs');
const path = require('path');

const root = path.join(__dirname, '..');
const src = fs.readFileSync(path.join(root, 'luci-app-mayhem/htdocs/luci-static/resources/mayhem/vpnkey.js'), 'utf8');
const body = src.replace(/^'require [^']*';$/mg, '');
global._ = (s) => s;

// LuCI adds String.prototype.format; enough of it for %s.
if (!String.prototype.format)
	String.prototype.format = function(...a) { let i = 0; return this.replace(/%s/g, () => String(a[i++])); };

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

	// The name of the key, and other ways the JSON may be packed.
	const zlib = require('zlib');
	const raw = key.trim().replace(/^vpn:\/\//, '').replace(/-/g, '+').replace(/_/g, '/');
	const json = zlib.inflateSync(Buffer.from(raw, 'base64').subarray(4));
	const enc = (b) => 'vpn://' + b.toString('base64').replace(/\+/g, '-').replace(/\//g, '_').replace(/=+$/, '');
	const r = await mod.read(key);

	if (r.name !== 'Test' || r.conf !== want) {
		console.log('FAIL read(): name "' + r.name + '"');
		failed++;
	}

	for (const [ what, k ] of [ [ 'bare zlib', enc(zlib.deflateSync(json)) ], [ 'raw deflate', enc(Buffer.concat([ Buffer.alloc(4), zlib.deflateRawSync(json) ])) ],
		[ 'plain JSON', enc(json) ] ]) {
		try {
			if (await mod.decode(k) !== want) {
				console.log('FAIL ' + what + ': wrong config');
				failed++;
			}
		}
		catch (e) {
			console.log('FAIL ' + what + ': ' + e.message);
			failed++;
		}
	}

	// An Amnezia Premium key: an account, not a config; the error says how to
	// get one.
	const premium = Buffer.from(JSON.stringify({ name: 'Amnezia Premium', config_version: 2,
		api_config: { service_type: 'amnezia-premium', service_protocol: 'awg' }, auth_data: { api_key: 'x' } }));
	const plen = Buffer.alloc(4);

	plen.writeUInt32BE(premium.length);

	try {
		await mod.decode(enc(Buffer.concat([ plen, zlib.deflateSync(premium) ])));
		console.log('FAIL a Premium key was accepted');
		failed++;
	}
	catch (e) {
		if (!/subscription key \(Amnezia Premium\)/.test(e.message)) {
			console.log('FAIL Premium key: ' + e.message);
			failed++;
		}
	}

	// A key cut short is an error, not a page that waits forever.
	const cut = key.trim().slice(0, Math.floor(key.trim().length * 0.6));
	const t0 = Date.now();

	try {
		await mod.decode(cut);
		console.log('FAIL a cut key was accepted');
		failed++;
	}
	catch (e) {
		if (Date.now() - t0 > 25000) {
			console.log('FAIL a cut key took ' + (Date.now() - t0) + ' ms');
			failed++;
		}
	}

	console.log(failed ? 'vpnkey: failed' : 'vpnkey: ok');
	process.exit(failed ? 1 : 0);
})();
