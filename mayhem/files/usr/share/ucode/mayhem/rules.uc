// Mayhem: normalization of user rules (domains, IP/CIDR) and DNS server strings.

'use strict';

// A domain as /^[a-z0-9_*-]+(\.[a-z0-9_-]+)*\.?$/ would match it, without
// the regexp: lists hold tens of thousands of domains, and musl's regexp
// takes ~0.1 ms for each on a router.
const DOMAIN_CHARS = 'abcdefghijklmnopqrstuvwxyz0123456789_-.*';

function domain_ok(d) {
	if (d == '' || ltrim(d, DOMAIN_CHARS) != '' || substr(d, 0, 1) == '.' || index(d, '..') >= 0)
		return false;

	const dot = index(d, '.');

	return dot < 0 || index(substr(d, dot), '*') < 0;
}

export function is_true(v) {
	return v === true || v === 1 || v == '1' || v == 'true' || v == 'yes' || v == 'on';
};

export function as_list(v) {
	if (v == null || v == '')
		return [];

	return type(v) == 'array' ? v : [ v ];
};

// Expands list values that may hold several entries separated by spaces,
// commas or new lines (textarea input). A regexp: keeps its commas
// (^ex[0-9]{1,3}\.com$): from it on, the rest of the word is the regexp.
export function entries(v) {
	const out = [];

	for (let item in as_list(v))
		for (let word in split(`${item}`, /[[:space:]]+/)) {
			const parts = split(word, ',');

			for (let i = 0; i < length(parts); i++) {
				let e = parts[i];

				if (substr(e, 0, 7) == 'regexp:') {
					e = join(',', slice(parts, i));
					i = length(parts);
				}

				if (e != '' && substr(e, 0, 1) != '#')
					push(out, e);
			}
		}

	return out;
};

const CATEGORY_RE = /^[a-z0-9][a-z0-9_!.-]*$/;
const SOURCE_RE = /^[A-Za-z0-9_]+$/;

// "geosite:CAT", "geosite:SOURCE:CAT", with an optional "@attribute" for geosite
// and "!" (everything except) for geoip. Returns { kind, source, cat, attr, neg }
// or { error }. Categories are case-insensitive.
export function geo_ref(kind, val, orig) {
	let neg = false, attr = '';

	if (kind == 'geoip' && substr(val, 0, 1) == '!') {
		neg = true;
		val = substr(val, 1);
	}

	const parts = split(val, ':');

	if (length(parts) > 2)
		return { error: `invalid category in "${orig}"` };

	const source = length(parts) == 2 ? parts[0] : null;
	let cat = lc(parts[length(parts) - 1]);

	if (kind == 'geosite') {
		const at = index(cat, '@');

		if (at >= 0) {
			attr = substr(cat, at);
			cat = substr(cat, 0, at);

			if (!match(attr, /^@[a-z0-9!_-]+$/))
				return { error: `invalid attribute in "${orig}"` };
		}
	}

	if (source != null && !match(source, SOURCE_RE))
		return { error: `invalid source name in "${orig}"` };

	if (!match(cat, CATEGORY_RE))
		return { error: `invalid category in "${orig}"` };

	return { kind: kind, source: source, cat: cat, attr: attr, neg: neg };
};

// --- names in other scripts (IDN) -----------------------------------------------
// пример.рф is xn--e1afmkfd.xn--p1ai on the wire (SNI, DNS): xray and dnsmasq
// only know the second form. Punycode of RFC 3492; capital letters of the
// Cyrillic and Latin-1 alphabets are made small first (lc() only knows
// ASCII).

function code_points(s) {
	const out = [];

	for (let i = 0; i < length(s); ) {
		const c = ord(s, i);
		let n = 0, cp = c;

		if (c >= 0xf0) { n = 3; cp = c & 0x07; }
		else if (c >= 0xe0) { n = 2; cp = c & 0x0f; }
		else if (c >= 0xc0) { n = 1; cp = c & 0x1f; }
		else if (c >= 0x80) return null;

		for (let j = 1; j <= n; j++) {
			const x = ord(s, i + j);

			if (x == null || (x & 0xc0) != 0x80)
				return null;

			cp = (cp << 6) | (x & 0x3f);
		}

		if (cp >= 0x410 && cp <= 0x42f) cp += 0x20;
		else if (cp >= 0x400 && cp <= 0x40f) cp += 0x50;
		else if (cp >= 0xc0 && cp <= 0xde && cp != 0xd7) cp += 0x20;

		push(out, cp);
		i += n + 1;
	}

	return out;
}

function puny_adapt(delta, points, first) {
	delta = first ? int(delta / 700) : int(delta / 2);
	delta += int(delta / points);

	let k = 0;

	for (; delta > 455; k += 36)
		delta = int(delta / 35);

	return k + int(36 * delta / (delta + 38));
}

function puny_digit(d) {
	return chr(d < 26 ? 97 + d : 22 + d);
}

function punycode(cps) {
	let out = '';

	for (let c in cps)
		if (c < 128)
			out += chr(c);

	const b = length(out);
	let h = b, n = 128, delta = 0, bias = 72;

	if (b)
		out += '-';

	while (h < length(cps)) {
		let m = 0x10ffff;

		for (let c in cps)
			if (c >= n && c < m)
				m = c;

		delta += (m - n) * (h + 1);
		n = m;

		for (let c in cps) {
			if (c < n)
				delta++;

			if (c == n) {
				let q = delta;

				for (let k = 36; ; k += 36) {
					const t = k <= bias ? 1 : (k >= bias + 26 ? 26 : k - bias);

					if (q < t)
						break;

					out += puny_digit(t + (q - t) % (36 - t));
					q = int((q - t) / (36 - t));
				}

				out += puny_digit(q);
				bias = puny_adapt(delta, h + 1, h == b);
				delta = 0;
				h++;
			}
		}

		delta++;
		n++;
	}

	return out;
}

// The ASCII form of a name, label by label; null when it is not UTF-8.
export function idn_ascii(d) {
	const out = [];

	for (let l in split(d, '.')) {
		const cps = code_points(l);

		if (cps == null)
			return null;

		push(out, length(filter(cps, (c) => c >= 128)) ? `xn--${punycode(cps)}` : l);
	}

	return join('.', out);
};

// Lists are long and all but a few names are ASCII: only a name that is
// not a domain as it is gets the conversion.
function ascii_domain(d) {
	if (domain_ok(d))
		return d;

	for (let i = 0; i < length(d); i++)
		if (ord(d, i) >= 0x80)
			return idn_ascii(d) ?? d;

	return d;
}

// Returns { value } | { geo: { kind, source, cat, attr } } | { error }.
// Bare entries mean "domain and its subdomains" (xray "domain:").
export function norm_domain(s) {
	s = trim(s);

	const m = index(s, ':') > 0 ? match(s, /^([a-z]+):(.*)$/) : null;

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
			const d = ascii_domain(replace(lc(val), /^(\*\.|\.)/, ''));

			if (!domain_ok(d))
				return { error: `invalid domain "${s}"` };

			return { value: `${kind}:${d}` };

		case 'geosite':
			const g = geo_ref('geosite', val, s);

			return g.error ? g : { geo: g };

		case 'ext':
			return { error: `"${s}": use geosite:category or geosite:source:category` };

		default:
			return { error: `unknown prefix "${kind}:" in "${s}"` };
		}
	}

	let d = lc(s);

	if (substr(d, 0, 1) == '.')
		d = substr(d, 1);
	else if (substr(d, 0, 2) == '*.')
		d = substr(d, 2);

	d = ascii_domain(d);

	if (!domain_ok(d) || index(d, '*') >= 0)
		return { error: `invalid domain "${s}"` };

	return { value: `domain:${d}` };
};

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

// Returns { family: 4|6, cidr } | { geo: { kind, source, cat, neg } } | { error }.
// Host bits are cleared so the value is a valid nftables interval.
export function norm_ip(s) {
	s = trim(s);

	if (substr(s, 0, 6) == 'geoip:') {
		const g = geo_ref('geoip', substr(s, 6), s);

		return g.error ? g : { geo: g };
	}

	if (substr(s, 0, 4) == 'ext:')
		return { error: `"${s}": use geoip:category or geoip:source:category` };

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
};

export function is_ip(s) {
	return iptoarr(s ?? '') != null;
};

// User DNS string -> xray NameServerConfig fragment, or { error }.
// Accepted: "1.1.1.1", "1.1.1.1:53", "[2606:4700::1111]:53", "udp://host[:port]",
// "tcp://host[:port]", "https://host/path" (DoH). DoT is not available in Xray.
export function dns_server(s) {
	s = trim(s ?? '');

	if (s == '')
		return { error: 'empty DNS server' };

	if (match(s, /^(tls|dot):\/\//))
		return { error: `"${s}": DNS over TLS is not supported by Xray, use https:// (DoH) or quic:// (DoQ)` };

	let m;

	// DNS over QUIC: xray only asks it directly (quic+local), past the
	// routing; port 853 unless given.
	if ((m = match(s, /^(quic|doq|quic\+local):\/\/(\[[0-9A-Fa-f:.]+\]|[^/:]+)(:([0-9]+))?\/?$/))) {
		const host = replace(m[2], /^\[|\]$/g, '');

		return { address: `quic+local://${m[2]}${m[3] ?? ''}`, host: host, direct: true };
	}

	if ((m = match(s, /^https:\/\/(\[[0-9A-Fa-f:.]+\]|[^/:]+)(:[0-9]+)?(\/.*)?$/))) {
		const host = replace(m[1], /^\[|\]$/g, '');

		if (m[2] != null && m[2] != '' && (int(substr(m[2], 1)) < 1 || int(substr(m[2], 1)) > 65535))
			return { error: `invalid port in DNS server "${s}"` };

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

		if (m[3] != null && m[3] != '') {
			r.port = int(m[3]);

			// xray refuses to start with such a port
			if (r.port < 1 || r.port > 65535)
				return { error: `invalid port in DNS server "${s}"` };
		}

		return r;
	}

	return { error: `invalid DNS server "${s}"` };
};

// Rule list text (a downloaded or local list): one domain, rule or subnet per
// line; "#" starts a comment. Returns { domains: [], ips: [], bad: n }
// with raw entries (normalized by the caller).
// A list is read line by line, often with hundreds of thousands of lines on a
// slow router: regular expressions only where a plain character test cannot
// tell (they cost ~30 us a line in ucode).
export function split_list(text) {
	const res = { domains: [], ips: [], bad: 0 };

	for (let line in split(text ?? '', '\n')) {
		const h = index(line, '#');

		if (h >= 0)
			line = substr(line, 0, h);

		line = trim(line);

		if (line == '')
			continue;

		// hosts-file style "0.0.0.0 example.com"
		if (substr(line, 0, 7) == '0.0.0.0' || substr(line, 0, 9) == '127.0.0.1') {
			const hm = match(line, /^(0\.0\.0\.0|127\.0\.0\.1)[[:space:]]+([^[:space:]]+)$/);

			if (hm)
				line = hm[2];
		}

		const c = ord(line, 0);
		const digit = c >= 48 && c <= 57;

		if ((digit || index(line, ':') >= 0) &&
		    (match(line, /^[0-9.]+(\/[0-9]+)?$/) || match(line, /^[0-9A-Fa-f:]*:[0-9A-Fa-f:.]*(\/[0-9]+)?$/)))
			push(res.ips, line);
		else if (index(line, ' ') < 0 && index(line, '\t') < 0)
			push(res.domains, line);
		else
			res.bad++;
	}

	return res;
};

// File name for a downloaded list: two 32-bit string hashes of its URL.
export function list_key(url) {
	let a = 0x811c9dc5, b = 5381;

	for (let i = 0; i < length(url); i++) {
		const c = ord(url, i);

		a = ((a ^ c) * 0x01000193) & 0xffffffff;
		b = ((b << 5) + b + c) & 0xffffffff;
	}

	return sprintf('%08x%08x', a, b);
};

// Whether `dnsmasq --version` lists nftset among its compile-time options.
// A build without it says "no-nftset", which must not count.
export function dnsmasq_nftset(version) {
	return match(version ?? '', /(^|[ \t\n])nftset([ \t\n]|$)/) != null;
};
