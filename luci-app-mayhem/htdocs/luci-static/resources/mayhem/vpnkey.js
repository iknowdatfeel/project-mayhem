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

function inflate(bytes) {
	if (typeof DecompressionStream !== 'function')
		return Promise.reject(new Error(_('This browser cannot unpack vpn:// keys, paste the .conf text instead')));

	const stream = new Blob([ bytes ]).stream().pipeThrough(new DecompressionStream('deflate'));

	return new Response(stream).text();
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
		return /^\s*vpn:\/\//i.test(text || '');
	},

	// Resolves to the .conf text inside a vpn:// key.
	decode(key) {
		let bytes;

		try {
			bytes = bytesFromBase64Url(key.trim().replace(/^vpn:\/\//i, ''));
		}
		catch (e) {
			return Promise.reject(new Error(_('The key is not valid base64')));
		}

		// Old keys are plain JSON, current ones are compressed.
		const text = (bytes[0] === 0x7b)
			? Promise.resolve(new TextDecoder().decode(bytes))
			: inflate(bytes.subarray(4));

		return text.then((t) => {
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
			return conf.replace(/\$PRIMARY_DNS/g, j.dns1 || '1.1.1.1').replace(/\$SECONDARY_DNS/g, j.dns2 || '1.0.0.1');
		});
	}
});
