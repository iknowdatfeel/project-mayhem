// Mayhem: WireGuard / AmneziaWG client configs (.conf) for netifd.
//
// parse_conf() reads the [Interface] / [Peer] text that AmneziaVPN and
// WireGuard export; uci_sections() turns it into the network sections of the
// amneziawg (or wireguard) netifd protocol. The tunnel never gets a default
// route: only what Mayhem sends into it goes there.

'use strict';

// .conf key -> UCI option of the interface (lower-case keys).
const IFACE_KEYS = {
	privatekey: 'private_key',
	listenport: 'listen_port',
	mtu: 'mtu',
	jc: 'awg_jc', jmin: 'awg_jmin', jmax: 'awg_jmax',
	s1: 'awg_s1', s2: 'awg_s2', s3: 'awg_s3', s4: 'awg_s4',
	h1: 'awg_h1', h2: 'awg_h2', h3: 'awg_h3', h4: 'awg_h4',
	i1: 'awg_i1', i2: 'awg_i2', i3: 'awg_i3', i4: 'awg_i4', i5: 'awg_i5',
	headerprotectionkey: 'awg_header_protection_key',
	contentpaddingaddition: 'awg_content_padding_addition',
	rekeyaftertime: 'awg_rekey_after_time',
	rekeytimeout: 'awg_rekey_timeout',
	rejectaftertime: 'awg_reject_after_time',
	keepalivetimeout: 'awg_keepalive_timeout',
	maxhandshakeattempts: 'awg_max_handshake_attempts'
};

const BOOL_KEYS = { randomtrailers: 'awg_random_trailers', disablecookies: 'awg_disable_cookies' };

function split_list(v) {
	return filter(map(split(v ?? '', ','), (x) => trim(x)), (x) => x != '');
}

// Returns { iface: { key: value }, peers: [ { key: value } ] } with lower-case
// keys; repeated keys (Address, AllowedIPs) are joined with commas.
export function parse_conf(text) {
	const res = { iface: null, peers: [] };
	let cur = null;

	for (let line in split(replace(text ?? '', '\r', ''), '\n')) {
		line = trim(line);

		if (line == '' || substr(line, 0, 1) == '#' || substr(line, 0, 1) == ';')
			continue;

		const sec = match(line, /^\[([A-Za-z]+)\]$/);

		if (sec) {
			const n = lc(sec[1]);

			if (n == 'interface')
				cur = res.iface ??= {};
			else if (n == 'peer')
				push(res.peers, cur = {});
			else
				cur = null;

			continue;
		}

		const kv = match(line, /^([A-Za-z0-9]+)[[:space:]]*=[[:space:]]*(.*)$/);

		if (!kv || !cur)
			continue;

		const k = lc(kv[1]), v = trim(kv[2]);

		cur[k] = (cur[k] != null && (k == 'address' || k == 'allowedips' || k == 'dns')) ? `${cur[k]},${v}` : v;
	}

	if (!res.iface?.privatekey)
		die('no [Interface] with a PrivateKey');

	if (!length(res.peers) || !res.peers[0].publickey)
		die('no [Peer] with a PublicKey');

	return res;
};

// Is it AmneziaWG (obfuscation parameters present) or plain WireGuard?
export function is_amnezia(conf) {
	for (let k in [ 'jc', 'jmin', 'jmax', 's1', 's2', 'h1', 'h2', 'h3', 'h4', 'i1' ])
		if (conf.iface[k] != null)
			return true;

	return false;
};

function endpoint(v) {
	let m = match(v ?? '', /^\[([0-9A-Fa-f:.]+)\]:([0-9]+)$/);

	if (!m)
		m = match(v ?? '', /^([^:]+):([0-9]+)$/);

	return m ? { host: m[1], port: m[2] } : (v ? { host: v } : {});
}

// UCI sections for the network config. proto: "amneziawg" or "wireguard".
// Returns { iface: { option: value }, peers: [ { option: value } ], v6 }.
export function uci_sections(conf, proto) {
	const iface = { proto: proto };
	const amnezia = proto == 'amneziawg';

	for (let k in keys(conf.iface)) {
		const opt = IFACE_KEYS[k];

		if (opt && (amnezia || substr(opt, 0, 4) != 'awg_'))
			iface[opt] = conf.iface[k];
		else if (BOOL_KEYS[k] && amnezia)
			iface[BOOL_KEYS[k]] = match(lc(conf.iface[k]), /^(on|1|true|yes)$/) ? '1' : '0';
	}

	const addrs = split_list(conf.iface.address);

	if (!length(addrs))
		die('the [Interface] has no Address');

	iface.addresses = addrs;

	const peers = [];

	for (let p in conf.peers) {
		if (!p.publickey)
			continue;

		const ep = endpoint(p.endpoint);
		const peer = {
			public_key: p.publickey,
			allowed_ips: length(split_list(p.allowedips)) ? split_list(p.allowedips) : [ '0.0.0.0/0', '::/0' ],
			// Mayhem decides what goes into the tunnel.
			route_allowed_ips: '0',
			description: 'Mayhem'
		};

		if (p.presharedkey) peer.preshared_key = p.presharedkey;
		if (ep.host) peer.endpoint_host = ep.host;
		if (ep.port) peer.endpoint_port = ep.port;
		if (p.persistentkeepalive) peer.persistent_keepalive = p.persistentkeepalive;

		push(peers, peer);
	}

	return { iface: iface, peers: peers, v6: length(filter(addrs, (a) => index(a, ':') >= 0)) > 0 };
};
