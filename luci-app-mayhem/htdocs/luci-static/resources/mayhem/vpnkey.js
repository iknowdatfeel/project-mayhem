'use strict';
'require baseclass';

// AmneziaVPN keys: "vpn://" + base64url(qCompress(JSON)). qCompress is a
// 4-byte big-endian length followed by a zlib stream, which the browser
// inflates with DecompressionStream('deflate'). The router has no zlib for
// ucode, so keys are decoded here and only the .conf text is sent to it.

function bytesFromBase64Url(s) {
	let b64 = s.replace(/[\s]/g, '').replace(/-/g, '+').replace(/_/g, '/');

	while (b64.length % 4)
		b64 += '=';

	const bin = atob(b64);
	const out = new Uint8Array(bin.length);

	for (let i = 0; i < bin.length; i++)
		out[i] = bin.charCodeAt(i);

	return out;
}

// The browser's Response: inside LuCI modules the name is LuCI's own HTTP
// response class, which takes an XMLHttpRequest.
const WebResponse = globalThis.Response;

// One way to unpack: a stream format and how many leading bytes to skip.
// A broken stream must not leave the page waiting: each try has a limit.
function unpack(bytes, format, skip) {
	const stream = new Blob([ bytes.subarray(skip) ]).stream().pipeThrough(new DecompressionStream(format));
	let timer;
	const limit = new Promise((resolve, reject) => {
		timer = setTimeout(() => reject(new Error('timeout')), 5000);
	});

	return Promise.race([ new WebResponse(stream).text(), limit ]).finally(() => clearTimeout(timer));
}

// qCompress (4-byte length + zlib) is what the app writes; a bare zlib or
// raw deflate stream is tried too, then plain JSON.
function inflate(bytes) {
	if (bytes[0] === 0x7b)
		return Promise.resolve(new TextDecoder().decode(bytes));

	if (typeof DecompressionStream !== 'function')
		return Promise.reject(new Error(_('This browser cannot unpack vpn:// keys, paste the .conf text instead')));

	const tries = [ [ 'deflate', 4 ], [ 'deflate', 0 ], [ 'deflate-raw', 4 ], [ 'deflate-raw', 0 ] ];
	const next = (i) => i >= tries.length
		? Promise.reject(new Error(_('The key could not be unpacked: it may be cut short. Copy it again, or paste the .conf text instead.')))
		: unpack(bytes, tries[i][0], tries[i][1]).then((t) => {
			JSON.parse(t);
			return t;
		}).catch(() => next(i + 1));

	return next(0);
}

// The WireGuard config sits in containers[].awg.last_config (a JSON string)
// under "config"; search for it instead of relying on one layout.
function findConf(obj) {
	if (!obj || typeof obj !== 'object')
		return null;

	if (typeof obj.config === 'string' && obj.config.indexOf('[Interface]') >= 0)
		return obj.config;

	if (typeof obj.last_config === 'string') {
		try {
			const r = findConf(JSON.parse(obj.last_config));

			if (r)
				return r;
		}
		catch (e) {}
	}

	for (const k in obj) {
		const r = findConf(obj[k]);

		if (r)
			return r;
	}

	return null;
}

return baseclass.extend({
	isKey(text) {
		return (/^\s*vpn:\/\//i).test(text || '');
	},

	// Resolves to the .conf text inside a vpn:// key.
	decode(key) {
		return this.read(key).then((r) => r.conf);
	},

	// Resolves to { conf, name }: the .conf text and the key's description.
	read(key) {
		let bytes;

		try {
			bytes = bytesFromBase64Url(key.trim().replace(/^vpn:\/\//i, ''));
		}
		catch (e) {
			return Promise.reject(new Error(_('The key is not valid base64')));
		}

		return inflate(bytes).then((t) => {
			let j;

			try {
				j = JSON.parse(t);
			}
			catch (e) {
				throw new Error(_('The key does not hold a configuration'));
			}

			const conf = findConf(j);

			if (!conf)
				throw new Error(_('The key holds no WireGuard/AmneziaWG configuration. Keys of AmneziaVPN subscriptions only work in the app: export a .conf there instead.'));

			// The app fills these in; Mayhem uses its own DNS anyway.
			return {
				conf: conf.replace(/\$PRIMARY_DNS/g, j.dns1 || '1.1.1.1').replace(/\$SECONDARY_DNS/g, j.dns2 || '1.0.0.1'),
				name: typeof j.description === 'string' ? j.description.trim() : ''
			};
		});
	}
});
