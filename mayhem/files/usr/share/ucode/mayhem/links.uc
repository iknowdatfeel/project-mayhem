// Mayhem: share-link parser.
// Turns a proxy URI (vless://, vmess://, trojan://, ss://, socks://, http(s)://,
// hysteria2:// / hy2://, wireguard:// / wg://) into an Xray outbound object.
// Every failure is raised with die() so callers can wrap parse_link() in try/catch.

'use strict';

export function urldecode(s) {
	if (s == null)
		return null;

	return replace(s, /%([0-9A-Fa-f]{2})/g, (m, h) => chr(hex(h)));
}

// Tolerant base64: accepts url-safe alphabet, missing padding and whitespace.
export function b64(s) {
	if (s == null)
		return null;

	s = replace(s, /[[:space:]]/g, '');
	s = replace(replace(s, /-/g, '+'), /_/g, '/');

	while (length(s) % 4)
		s += '=';

	return b64dec(s);
}

function parse_query(q) {
	const r = {};

	for (let kv in split(q ?? '', '&')) {
		if (kv == '')
			continue;

		const i = index(kv, '=');
		const k = lc(urldecode(i < 0 ? kv : substr(kv, 0, i)));

		r[k] = urldecode(i < 0 ? '' : substr(kv, i + 1));
	}

	return r;
}

function parse_port(p) {
	if (!match(p ?? '', /^[0-9]+$/))
		die(`invalid port "${p}"`);

	const n = int(p);

	if (n < 1 || n > 65535)
		die(`port out of range: ${n}`);

	return n;
}

// scheme://userinfo@host:port/path?query#fragment
// userinfo may contain '/' (base64), so the query is cut first and the
// userinfo is everything before the last '@'.
function parse_url(link) {
	const m = match(link, /^([A-Za-z][A-Za-z0-9+.-]*):\/\/([^#]*)(#(.*))?$/s);

	if (!m)
		die('not a URL');

	const u = {
		scheme: lc(m[1]),
		name: urldecode(m[4]) ?? '',
		user: null,
		host: null,
		port: null,
		path: '',
		query: {}
	};

	let rest = m[2];
	const qi = index(rest, '?');

	if (qi >= 0) {
		u.query = parse_query(substr(rest, qi + 1));
		rest = substr(rest, 0, qi);
	}

	const ai = rindex(rest, '@');

	if (ai >= 0) {
		u.user = substr(rest, 0, ai);
		rest = substr(rest, ai + 1);
	}

	const pi = index(rest, '/');

	if (pi >= 0) {
		u.path = substr(rest, pi);
		rest = substr(rest, 0, pi);
	}

	let hm;

	if ((hm = match(rest, /^\[([0-9A-Fa-f:.]+)\](:([0-9]+))?$/))) {
		u.host = hm[1];
		u.port = hm[3];
	}
	else if ((hm = match(rest, /^([^:]+)(:([0-9,-]+))?$/))) {
		u.host = hm[1];
		u.port = hm[3];
	}
	else {
		die(`invalid host part "${rest}"`);
	}

	return u;
}

function csv(s) {
	return filter(map(split(s ?? '', ','), (x) => trim(x)), (x) => x != '');
}

function nonempty(v) {
	return v != null && v != '';
}

// Builds streamSettings from the common v2rayN-style query parameters.
// `p` keys are lower-cased. `warn` collects non-fatal notes.
function stream_settings(p, def_security, warn) {
	let net = lc(p.type ?? 'tcp');
	const sec = lc(nonempty(p.security) ? p.security : def_security);
	const ss = {};

	switch (net) {
	case '':
	case 'tcp':
	case 'raw':
		ss.network = 'raw';

		if (lc(p.headertype ?? '') == 'http') {
			const req = { path: [ nonempty(p.path) ? p.path : '/' ] };

			if (nonempty(p.host))
				req.headers = { Host: csv(p.host) };

			ss.rawSettings = { header: { type: 'http', request: req } };
		}
		break;

	case 'ws':
	case 'websocket':
		ss.network = 'ws';
		ss.wsSettings = {};

		if (nonempty(p.path))
			ss.wsSettings.path = p.path;

		if (nonempty(p.host))
			ss.wsSettings.host = p.host;
		break;

	case 'httpupgrade':
		ss.network = 'httpupgrade';
		ss.httpupgradeSettings = {};

		if (nonempty(p.path))
			ss.httpupgradeSettings.path = p.path;

		if (nonempty(p.host))
			ss.httpupgradeSettings.host = p.host;
		break;

	case 'grpc':
	case 'gun':
		ss.network = 'grpc';
		ss.grpcSettings = { serviceName: p.servicename ?? p.path ?? '' };

		if (lc(p.mode ?? '') == 'multi')
			ss.grpcSettings.multiMode = true;

		if (nonempty(p.authority))
			ss.grpcSettings.authority = p.authority;
		break;

	case 'xhttp':
	case 'splithttp':
		ss.network = 'xhttp';
		ss.xhttpSettings = { mode: nonempty(p.mode) ? p.mode : 'auto' };

		if (nonempty(p.path))
			ss.xhttpSettings.path = p.path;

		if (nonempty(p.host))
			ss.xhttpSettings.host = p.host;

		if (nonempty(p.extra)) {
			try {
				ss.xhttpSettings.extra = json(p.extra);
			}
			catch (e) {
				push(warn, 'xhttp "extra" is not valid JSON, ignored');
			}
		}
		break;

	case 'h2':
	case 'http':
	case 'quic':
		die(`transport "${net}" was removed from Xray, ask the provider for an XHTTP link`);

	default:
		die(`unsupported transport "${net}"`);
	}

	switch (sec) {
	case '':
	case 'none':
		break;

	case 'tls':
		ss.security = 'tls';
		ss.tlsSettings = {};

		if (nonempty(p.sni))
			ss.tlsSettings.serverName = p.sni;
		else if (nonempty(p.peer))
			ss.tlsSettings.serverName = p.peer;

		if (nonempty(p.fp))
			ss.tlsSettings.fingerprint = p.fp;

		if (nonempty(p.alpn))
			ss.tlsSettings.alpn = csv(p.alpn);

		if (nonempty(p.pcs))
			ss.tlsSettings.pinnedPeerCertSha256 = p.pcs;

		if (nonempty(p.vcn))
			ss.tlsSettings.verifyPeerCertByName = p.vcn;

		if (nonempty(p.ech))
			ss.tlsSettings.echConfigList = p.ech;

		if (p.allowinsecure == '1' || p.allowinsecure == 'true' ||
		    p.insecure == '1' || p.insecure == 'true')
			push(warn, 'insecure TLS is no longer supported by Xray; the certificate will be verified (pin it with "pcs" if needed)');
		break;

	case 'reality':
		if (!nonempty(p.pbk))
			die('REALITY link has no public key (pbk)');

		ss.security = 'reality';
		ss.realitySettings = {
			fingerprint: nonempty(p.fp) ? p.fp : 'chrome',
			password: p.pbk
		};

		if (nonempty(p.sni))
			ss.realitySettings.serverName = p.sni;

		if (nonempty(p.sid))
			ss.realitySettings.shortId = p.sid;

		if (nonempty(p.spx))
			ss.realitySettings.spiderX = p.spx;

		if (nonempty(p.pqv))
			ss.realitySettings.mldsa65Verify = p.pqv;
		break;

	case 'xtls':
		die('legacy XTLS is not supported by Xray, use xtls-rprx-vision with TLS or REALITY');

	default:
		die(`unsupported security "${sec}"`);
	}

	return ss;
}

function need_host(u) {
	if (!nonempty(u.host))
		die('server address is missing');

	if (!nonempty(u.port))
		die('server port is missing');

	// Port hopping ranges ("443,2000-3000") are not supported yet: use the first port.
	if (!match(u.port, /^[0-9]+$/))
		die(`port ranges are not supported yet: "${u.port}"`);
}

function parse_vless(u, warn) {
	need_host(u);

	const id = urldecode(u.user);

	if (!nonempty(id))
		die('VLESS link has no user id');

	const p = u.query;
	const settings = {
		address: u.host,
		port: parse_port(u.port),
		id: id,
		encryption: nonempty(p.encryption) ? p.encryption : 'none'
	};

	if (nonempty(p.flow))
		settings.flow = p.flow;

	return {
		protocol: 'vless',
		settings: settings,
		streamSettings: stream_settings(p, 'none', warn)
	};
}

function parse_trojan(u, warn) {
	need_host(u);

	const pass = urldecode(u.user);

	if (!nonempty(pass))
		die('Trojan link has no password');

	return {
		protocol: 'trojan',
		settings: { address: u.host, port: parse_port(u.port), password: pass },
		streamSettings: stream_settings(u.query, 'tls', warn)
	};
}

function parse_vmess(link, warn) {
	const body = substr(link, length('vmess://'));
	const hi = index(body, '#');
	const raw = b64(hi >= 0 ? substr(body, 0, hi) : body);
	let j;

	try {
		j = json(raw);
	}
	catch (e) {
		die('VMess link is not base64 JSON');
	}

	if (type(j) != 'object' || !nonempty(j.add) || !nonempty(`${j.port ?? ''}`) || !nonempty(j.id))
		die('VMess link misses add/port/id');

	const net = lc(nonempty(j.net) ? j.net : 'tcp');
	const p = {
		type: net,
		security: (j.tls == 'tls' || j.tls == 'reality') ? j.tls : 'none',
		sni: j.sni,
		alpn: j.alpn,
		fp: j.fp,
		host: j.host,
		path: j.path,
		pbk: j.pbk,
		sid: j.sid,
		spx: j.spx
	};

	if (net == 'grpc') {
		p.servicename = j.path;
		p.mode = j.type;
	}
	else if (net == 'xhttp' || net == 'splithttp') {
		p.mode = j.type;
	}
	else {
		p.headertype = j.type;
	}

	return {
		name: j.ps ?? '',
		outbound: {
			protocol: 'vmess',
			settings: {
				address: j.add,
				port: parse_port(`${j.port}`),
				id: j.id,
				security: nonempty(j.scy) ? j.scy : 'auto'
			},
			streamSettings: stream_settings(p, 'none', warn)
		}
	};
}

function parse_ss(link, warn) {
	let u;

	try {
		u = parse_url(link);
	}
	catch (e) {
		u = null;
	}

	// Legacy form: ss://BASE64(method:password@host:port)#name
	if (!u || u.user == null) {
		const body = substr(link, length('ss://'));
		const hi = index(body, '#');
		const dec = b64(hi >= 0 ? substr(body, 0, hi) : body);

		if (!dec)
			die('Shadowsocks link is neither SIP002 nor legacy base64');

		u = parse_url(`ss://${dec}${hi >= 0 ? substr(body, hi) : ''}`);
		u.user = urldecode(u.user);
	}

	need_host(u);

	if (nonempty(u.query.plugin))
		die('Shadowsocks plugins (SIP003) are not supported by Xray');

	let ui = urldecode(u.user);

	// SIP002: userinfo is base64(method:password) for stream ciphers,
	// plain percent-encoded "method:password" for 2022 ciphers.
	if (index(ui, ':') < 0) {
		const dec = b64(ui);

		if (!dec || index(dec, ':') < 0)
			die('Shadowsocks link has malformed credentials');

		ui = dec;
	}

	const ci = index(ui, ':');
	const settings = {
		address: u.host,
		port: parse_port(u.port),
		method: substr(ui, 0, ci),
		password: substr(ui, ci + 1)
	};

	if (u.query.uot == '1' || u.query.uot == 'true')
		settings.uot = true;

	return { name: u.name, outbound: { protocol: 'shadowsocks', settings: settings } };
}

function credentials(user) {
	if (!nonempty(user))
		return null;

	let s = urldecode(user);

	if (index(s, ':') < 0) {
		const dec = b64(user);

		if (dec && index(dec, ':') >= 0)
			s = dec;
	}

	const i = index(s, ':');

	return i < 0 ? { user: s, pass: '' } : { user: substr(s, 0, i), pass: substr(s, i + 1) };
}

function parse_socks_http(u, proto, tls) {
	need_host(u);

	const settings = { address: u.host, port: parse_port(u.port) };
	const c = credentials(u.user);

	if (c) {
		settings.user = c.user;
		settings.pass = c.pass;
	}

	const ob = { protocol: proto, settings: settings };

	if (tls) {
		ob.streamSettings = { network: 'raw', security: 'tls', tlsSettings: {} };

		if (nonempty(u.query.sni))
			ob.streamSettings.tlsSettings.serverName = u.query.sni;
	}

	return ob;
}

function parse_hysteria2(u, warn) {
	need_host(u);

	const p = u.query;
	const tls = { alpn: [ 'h3' ] };

	if (nonempty(p.sni))
		tls.serverName = p.sni;

	if (nonempty(p.pinsha256))
		tls.pinnedPeerCertSha256 = p.pinsha256;

	if (nonempty(p.alpn))
		tls.alpn = csv(p.alpn);

	if (p.insecure == '1' || p.insecure == 'true')
		push(warn, 'insecure TLS is no longer supported by Xray; the certificate will be verified (pin it with "pinSHA256" if needed)');

	if (nonempty(p.mport))
		push(warn, 'port hopping (mport) is not supported yet, the main port is used');

	const ss = {
		network: 'hysteria',
		security: 'tls',
		tlsSettings: tls,
		hysteriaSettings: { version: 2, auth: urldecode(u.user) ?? '' }
	};

	if (nonempty(p.obfs)) {
		if (lc(p.obfs) != 'salamander')
			die(`unsupported Hysteria2 obfuscation "${p.obfs}"`);

		ss.finalmask = { udp: [ { type: 'salamander', settings: { password: p['obfs-password'] ?? '' } } ] };
	}

	return {
		protocol: 'hysteria',
		settings: { version: 2, address: u.host, port: parse_port(u.port) },
		streamSettings: ss
	};
}

function parse_wireguard(u, warn) {
	need_host(u);

	const p = u.query;
	const key = urldecode(u.user);
	const pub = p.publickey ?? p.public_key ?? p.peer_public_key;

	if (!nonempty(key))
		die('WireGuard link has no private key');

	if (!nonempty(pub))
		die('WireGuard link has no peer public key');

	const addr = csv(p.address ?? p.ip);

	if (!length(addr))
		die('WireGuard link has no interface address');

	const host = index(u.host, ':') >= 0 ? `[${u.host}]` : u.host;
	const peer = { publicKey: pub, endpoint: `${host}:${parse_port(u.port)}` };
	const psk = p.presharedkey ?? p.pre_shared_key;

	if (nonempty(psk))
		peer.preSharedKey = psk;

	if (nonempty(p.keepalive) && match(p.keepalive, /^[0-9]+$/))
		peer.keepAlive = int(p.keepalive);

	const settings = {
		secretKey: key,
		address: addr,
		peers: [ peer ],
		noKernelTun: true
	};

	if (nonempty(p.mtu) && match(p.mtu, /^[0-9]+$/))
		settings.mtu = int(p.mtu);

	if (nonempty(p.reserved)) {
		const r = map(csv(p.reserved), (x) => match(x, /^[0-9]+$/) ? int(x) : -1);

		if (length(r) != 3 || length(filter(r, (n) => n >= 0 && n <= 255)) != 3)
			die('WireGuard "reserved" must be three numbers 0-255');

		settings.reserved = r;
	}

	return { protocol: 'wireguard', settings: settings };
}

// Returns { name, outbound, warnings[] }. Throws on malformed links.
export function parse_link(link) {
	link = trim(link ?? '');

	if (link == '')
		die('empty link');

	const warn = [];
	const m = match(link, /^([A-Za-z][A-Za-z0-9+.-]*):\/\//);

	if (!m)
		die('link has no scheme');

	const scheme = lc(m[1]);
	let r;

	switch (scheme) {
	case 'vmess':
		r = parse_vmess(link, warn);
		break;

	case 'ss':
		r = parse_ss(link, warn);
		break;

	default:
		const u = parse_url(link);

		r = { name: u.name };

		switch (scheme) {
		case 'vless':
			r.outbound = parse_vless(u, warn);
			break;

		case 'trojan':
			r.outbound = parse_trojan(u, warn);
			break;

		case 'socks':
		case 'socks5':
			r.outbound = parse_socks_http(u, 'socks', false);
			break;

		case 'http':
		case 'https':
			r.outbound = parse_socks_http(u, 'http', scheme == 'https');
			break;

		case 'hysteria2':
		case 'hy2':
			r.outbound = parse_hysteria2(u, warn);
			break;

		case 'wireguard':
		case 'wg':
			r.outbound = parse_wireguard(u, warn);
			break;

		default:
			die(`unsupported link type "${scheme}://"`);
		}
	}

	r.warnings = warn;

	return r;
}

// Server host of an outbound (for resolving it with the domestic DNS).
export function outbound_host(ob) {
	const s = ob?.settings ?? {};

	if (type(s.address) == 'string' && s.address != '')
		return s.address;

	if (length(s.vnext ?? []))
		return s.vnext[0].address;

	if (length(s.servers ?? []))
		return s.servers[0].address;

	if (length(s.peers ?? [])) {
		const ep = s.peers[0].endpoint ?? '';
		const m = match(ep, /^\[?([^\]]+?)\]?:[0-9]+$/);

		return m ? m[1] : null;
	}

	return null;
}

// Server port of an outbound (for TCP ping).
export function outbound_port(ob) {
	const s = ob?.settings ?? {};

	if (s.port)
		return int(s.port);

	if (length(s.vnext ?? []))
		return int(s.vnext[0].port);

	if (length(s.servers ?? []))
		return int(s.servers[0].port);

	if (length(s.peers ?? [])) {
		const m = match(s.peers[0].endpoint ?? '', /:([0-9]+)$/);

		return m ? int(m[1]) : null;
	}

	return null;
}

// True for protocols carried over UDP, where a TCP ping says nothing.
export function outbound_udp(ob) {
	return ob?.protocol == 'hysteria' || ob?.protocol == 'wireguard' ||
		ob?.streamSettings?.network == 'kcp';
}
