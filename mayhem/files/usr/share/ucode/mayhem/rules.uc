// Mayhem: normalization of user rules (domains, IP/CIDR) and DNS server strings.

'use strict';

const DOMAIN_RE = /^[a-z0-9_*-]+(\.[a-z0-9_-]+)*\.?$/;

export function is_true(v) {
	return v === true || v === 1 || v == '1' || v == 'true' || v == 'yes' || v == 'on';
}

export function as_list(v) {
	if (v == null || v == '')
		return [];

	return type(v) == 'array' ? v : [ v ];
}

// Expands list values that may hold several entries separated by spaces,
// commas or new lines (textarea input).
export function entries(v) {
	const out = [];

	for (let item in as_list(v))
		for (let e in split(`${item}`, /[[:space:],]+/))
			if (e != '' && substr(e, 0, 1) != '#')
				push(out, e);

	return out;
}

// Returns { value } | { geo: true } | { error }.
// Bare entries mean "domain and its subdomains" (xray "domain:").
export function norm_domain(s) {
	s = trim(s);

	const m = match(s, /^([a-z]+):(.*)$/);

	if (m) {
		const kind = m[1], val = m[2];

		switch (kind) {
		case 'regexp':
			if (val == '')
				return { error: `empty regexp in "${s}"` };

			return { value: s };

		case 'keyword':
			if (val == '')
				return { error: `empty keyword in "${s}"` };

			return { value: `keyword:${lc(val)}` };

		case 'domain':
		case 'full':
			const d = replace(lc(val), /^(\*\.|\.)/, '');

			if (!match(d, DOMAIN_RE))
				return { error: `invalid domain "${s}"` };

			return { value: `${kind}:${d}` };

		case 'geosite':
		case 'ext':
			return { geo: true };

		default:
			return { error: `unknown prefix "${kind}:" in "${s}"` };
		}
	}

	const d = replace(lc(s), /^(\*\.|\.)/, '');

	if (!match(d, DOMAIN_RE) || index(d, '*') >= 0)
		return { error: `invalid domain "${s}"` };

	return { value: `domain:${d}` };
}

function mask_bytes(bytes, prefix) {
	const out = [];

	for (let i = 0; i < length(bytes); i++) {
		const bits = prefix - i * 8;

		if (bits >= 8)
			push(out, bytes[i]);
		else if (bits <= 0)
			push(out, 0);
		else
			push(out, bytes[i] & ((0xff << (8 - bits)) & 0xff));
	}

	return out;
}

// Returns { family: 4|6, cidr } | { geo: true } | { error }.
// Host bits are cleared so the value is a valid nftables interval.
export function norm_ip(s) {
	s = trim(s);

	if (match(s, /^(geoip|ext):/))
		return { geo: true };

	const parts = split(s, '/');

	if (length(parts) > 2)
		return { error: `invalid address "${s}"` };

	const bytes = iptoarr(parts[0]);

	if (!bytes)
		return { error: `invalid address "${s}"` };

	const max = length(bytes) * 8;
	let prefix = max;

	if (length(parts) == 2) {
		if (!match(parts[1], /^[0-9]+$/) || int(parts[1]) > max)
			return { error: `invalid prefix in "${s}"` };

		prefix = int(parts[1]);
	}

	return {
		family: length(bytes) == 4 ? 4 : 6,
		cidr: `${arrtoip(mask_bytes(bytes, prefix))}/${prefix}`
	};
}

export function is_ip(s) {
	return iptoarr(s ?? '') != null;
}

// User DNS string -> xray NameServerConfig fragment, or { error }.
// Accepted: "1.1.1.1", "1.1.1.1:53", "[2606:4700::1111]:53", "udp://host[:port]",
// "tcp://host[:port]", "https://host/path" (DoH). DoT is not available in Xray.
export function dns_server(s) {
	s = trim(s ?? '');

	if (s == '')
		return { error: 'empty DNS server' };

	if (match(s, /^(tls|dot|quic):\/\//))
		return { error: `"${s}": DNS-over-TLS/QUIC is not supported by Xray, use https:// (DoH)` };

	let m;

	if ((m = match(s, /^https:\/\/(\[[0-9A-Fa-f:.]+\]|[^/:]+)(:[0-9]+)?(\/.*)?$/))) {
		const host = replace(m[1], /^\[|\]$/g, '');

		return { address: s, host: host };
	}

	if ((m = match(s, /^tcp:\/\/(\[[0-9A-Fa-f:.]+\]|[^/:]+)(:([0-9]+))?$/))) {
		const host = replace(m[1], /^\[|\]$/g, '');

		return { address: s, host: host };
	}

	s = replace(s, /^udp:\/\//, '');

	if ((m = match(s, /^\[([0-9A-Fa-f:.]+)\](:([0-9]+))?$/)) ||
	    (m = match(s, /^([0-9.]+)(:([0-9]+))?$/)) ||
	    (m = match(s, /^([0-9A-Fa-f:]+)()()$/))) {
		if (!is_ip(m[1]))
			return { error: `invalid DNS server "${s}"` };

		const r = { address: m[1], host: m[1] };

		if (m[3] != null && m[3] != '')
			r.port = int(m[3]);

		return r;
	}

	return { error: `invalid DNS server "${s}"` };
}
