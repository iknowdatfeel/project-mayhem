// Mayhem: geosite/geoip .dat files (protobuf GeoSiteList / GeoIPList).
//
// A full geosite.dat is ~70 MB, more than a router has free on flash, so it is
// never stored: scan() reads the download as a stream, counts the rules of
// every category for the GUI and copies only the selected categories into a
// small file that xray loads as ext:<file>:<category>. The selected records
// are copied byte for byte: a .dat with fewer records is still a valid .dat.
//
// Both formats share the outer shape:
//   list    = repeated entry (field 1, length-delimited)
//   entry   = country_code (field 1, string) + repeated rule (field 2)
//   geosite rule = Domain { type (1), value (2), attributes (3) }
//   geoip rule   = CIDR { ip (1, 4 or 16 bytes), prefix (2) }; reverse_match (3)

'use strict';

import { is_true, entries, norm_domain, norm_ip } from 'mayhem.rules';

const CHUNK = 65536;

// Categories bigger than this make xray use a lot of memory.
export const HEAVY = 50000;

// Streaming reader over a handle with read(n). Bytes between capture()
// and release() are written to `out` as they go by.
function reader(fh) {
	const r = {
		buf: '', pos: 0, base: 0, eof: false, cap: -1, out: null,

		at() {
			return this.base + this.pos;
		},

		flush() {
			if (this.cap >= 0) {
				if (this.pos > this.cap)
					this.out.write(substr(this.buf, this.cap, this.pos - this.cap));

				this.cap = this.pos;
			}
		},

		fill(n) {
			while (length(this.buf) - this.pos < n && !this.eof) {
				const d = fh.read(CHUNK);

				if (d == null || length(d) == 0) {
					this.eof = true;
					break;
				}

				this.flush();
				this.base += this.pos;
				this.buf = substr(this.buf, this.pos) + d;

				if (this.cap >= 0)
					this.cap = 0;

				this.pos = 0;
			}

			return length(this.buf) - this.pos >= n;
		},

		varint() {
			this.fill(10);

			let v = 0, sh = 0;

			while (this.pos < length(this.buf)) {
				const b = ord(this.buf, this.pos++);

				v |= (b & 0x7f) << sh;

				if (b < 0x80)
					return v;

				sh += 7;
			}

			die('truncated data');
		},

		skip(n) {
			while (n > 0) {
				const avail = length(this.buf) - this.pos;

				if (avail >= n) {
					this.pos += n;
					return;
				}

				this.pos += avail;
				n -= avail;

				if (!this.fill(1))
					die('truncated data');
			}
		},

		bytes(n) {
			if (!this.fill(n))
				die('truncated data');

			const s = substr(this.buf, this.pos, n);

			this.pos += n;

			return s;
		},

		// Skips a field of the given wire type.
		skip_field(wt) {
			switch (wt) {
			case 0: this.varint(); break;
			case 1: this.skip(8); break;
			case 2: this.skip(this.varint()); break;
			case 5: this.skip(4); break;
			default: die(`unsupported wire type ${wt}`);
			}
		},

		capture(out) {
			this.out = out;
			this.cap = this.pos;
		},

		release() {
			this.flush();
			this.cap = -1;
		}
	};

	return r;
}

function encode_varint(v) {
	let s = '';

	while (v >= 0x80) {
		s += chr((v & 0x7f) | 0x80);
		v >>= 7;
	}

	return s + chr(v);
}

// Reads one entry header: returns { name, end } with the reader positioned
// after the name, or null at the end of the list.
function entry_head(r) {
	if (!r.fill(1))
		return null;

	const tag = r.varint();

	if (tag != 0x0a)
		die(`unexpected field ${tag >> 3} in the list`);

	const len = r.varint();
	const end = r.at() + len;

	return { len: len, end: end };
}

// Scans a whole .dat stream.
//   fh    handle to read from (file, pipe, stdin)
//   want  { CATEGORY (upper case): true } - entries to copy to `out`
//   out   handle to write the copied entries to (or null)
// Returns { categories: { name (lower case): rule count }, copied: [ names ], bytes }.
export function scan(fh, want, out) {
	const r = reader(fh);
	const cats = {};
	const copied = [];

	want ??= {};

	while (true) {
		const start = r.at();

		if (!r.fill(1))
			break;

		const tag = r.varint();

		if (tag != 0x0a)
			die(`not a geosite/geoip file (field ${tag >> 3} at offset ${start})`);

		const len = r.varint();
		const end = r.at() + len;
		let name = null, count = 0, copying = false;

		// Hot loop: rules are short records with a one-byte tag and length.
		// Work on local copies of the buffer state and fall back to the
		// reader for everything else (refills, long records, other fields).
		let buf = r.buf, pos = r.pos, blen = length(buf), lim = end - r.base;

		while (pos < lim) {
			if (blen - pos < 24) {
				r.pos = pos;
				r.fill(24);
				buf = r.buf; pos = r.pos; blen = length(buf); lim = end - r.base;

				if (pos >= lim)
					break;
			}

			if (ord(buf, pos) == 0x12) {
				const l = ord(buf, pos + 1);

				if (l < 0x80 && pos + 2 + l <= blen) {
					pos += 2 + l;
					count++;
					continue;
				}
			}

			r.pos = pos;

			const ft = r.varint();
			const field = ft >> 3, wt = ft & 7;

			if (field == 1 && wt == 2) {
				name = r.bytes(r.varint());

				if (want[uc(name)] && out) {
					// The tag and length were already read: write them out,
					// then capture the rest of the entry as it streams by.
					out.write(chr(0x0a) + encode_varint(len) + chr(0x0a) + encode_varint(length(name)) + name);
					r.capture(out);
					copying = true;
					push(copied, lc(name));
				}
			}
			else if (field == 2) {
				r.skip_field(wt);
				count++;
			}
			else {
				r.skip_field(wt);
			}

			buf = r.buf; pos = r.pos; blen = length(buf); lim = end - r.base;
		}

		r.pos = pos;

		if (copying)
			r.release();

		if (r.at() != end)
			die('broken entry length');

		if (name == null)
			die('entry without a name');

		cats[lc(name)] = (cats[lc(name)] ?? 0) + count;
	}

	return { categories: cats, copied: copied, bytes: r.at() };
}

// Trimmed files are small (the categories in use), so they are read whole and
// parsed with plain string offsets: on a router this is much faster than the
// streaming reader. vint() returns [value, next offset].
function vint(b, p) {
	let v = 0, sh = 0;

	while (true) {
		const c = ord(b, p++);

		if (c == null)
			die('truncated data');

		v |= (c & 0x7f) << sh;

		if (c < 0x80)
			return [ v, p ];

		sh += 7;
	}
}

// Offset after a field of wire type wt that starts at p (after its tag).
function skip_at(b, p, wt) {
	switch (wt) {
	case 0: return vint(b, p)[1];
	case 1: return p + 8;
	case 2: const l = vint(b, p); return l[1] + l[0];
	case 5: return p + 4;
	default: die(`unsupported wire type ${wt}`);
	}
}

// Calls fn(name, body_start, body_end) for every wanted entry of a .dat file.
function each_entry(path, cats, fn) {
	const b = require('fs').readfile(path);

	if (b == null)
		return;

	const want = {};

	for (let c in cats)
		want[uc(c)] = true;

	const n = length(b);
	let p = 0;

	while (p < n) {
		if (ord(b, p) != 0x0a)
			die(`${path}: not a geosite/geoip file`);

		const l = vint(b, p + 1);
		const end = l[1] + l[0];

		p = l[1];

		// The name comes first in every entry.
		if (ord(b, p) == 0x0a) {
			const nl = vint(b, p + 1);
			const name = substr(b, nl[1], nl[0]);

			if (want[uc(name)])
				fn(lc(name), b, nl[1] + nl[0], end);
		}

		p = end;
	}
}

// Reads the selected geoip categories from a trimmed file.
// Returns { category (lower case): { v4: [cidr], v6: [cidr], reverse: bool } }.
export function geoip_cidrs(path, cats) {
	const res = {};

	each_entry(path, cats, (name, b, p, end) => {
		const item = res[name] = { v4: [], v6: [], reverse: false };

		while (p < end) {
			const t = ord(b, p++);

			if (t == 0x12) {
				const l = vint(b, p);
				const q = l[1], ce = l[1] + l[0];

				// CIDR { ip (field 1, 4 or 16 bytes), prefix (field 2) }
				if (ord(b, q) == 0x0a) {
					const il = ord(b, q + 1), ip = q + 2;
					let prefix = il * 8;

					if (ord(b, ip + il) == 0x10 && ip + il + 1 < ce)
						prefix = vint(b, ip + il + 1)[0];

					if (il == 4 && prefix <= 32)
						push(item.v4, sprintf('%d.%d.%d.%d/%d', ord(b, ip), ord(b, ip + 1), ord(b, ip + 2), ord(b, ip + 3), prefix));
					else if (il == 16 && prefix <= 128)
						push(item.v6, sprintf('%x:%x:%x:%x:%x:%x:%x:%x/%d',
							ord(b, ip) << 8 | ord(b, ip + 1), ord(b, ip + 2) << 8 | ord(b, ip + 3),
							ord(b, ip + 4) << 8 | ord(b, ip + 5), ord(b, ip + 6) << 8 | ord(b, ip + 7),
							ord(b, ip + 8) << 8 | ord(b, ip + 9), ord(b, ip + 10) << 8 | ord(b, ip + 11),
							ord(b, ip + 12) << 8 | ord(b, ip + 13), ord(b, ip + 14) << 8 | ord(b, ip + 15),
							prefix));
				}

				p = ce;
			}
			else if (t == 0x18) {
				const v = vint(b, p);

				item.reverse = v[0] != 0;
				p = v[1];
			}
			else {
				p = skip_at(b, p, t & 7);
			}
		}
	});

	return res;
}

// Domain types in geosite: 0 keyword (plain), 1 regexp, 2 domain, 3 full.
const DOMAIN_TYPES = [ 'keyword', 'regexp', 'domain', 'full' ];

// Reads the selected geosite categories from a trimmed file.
// Returns { category (lower case): [ "domain:x", "full:y", "keyword:z", "regexp:w" ] }.
// Attributes (@cn and so on) are not kept.
export function geosite_domains(path, cats) {
	const res = {};

	each_entry(path, cats, (name, b, p, end) => {
		const item = res[name] = [];

		while (p < end) {
			const t = ord(b, p++);

			if (t == 0x12) {
				const l = vint(b, p);
				const de = l[1] + l[0];
				let q = l[1], dt = 0, value = null;

				// Domain { type (field 1), value (field 2), attributes (field 3) }
				while (q < de) {
					const dtag = ord(b, q++);

					if (dtag == 0x08) {
						const v = vint(b, q);

						dt = v[0];
						q = v[1];
					}
					else if (dtag == 0x12) {
						const v = vint(b, q);

						value = substr(b, v[1], v[0]);
						q = v[1] + v[0];
					}
					else {
						q = skip_at(b, q, dtag & 7);
					}
				}

				if (value != null && DOMAIN_TYPES[dt])
					push(item, `${DOMAIN_TYPES[dt]}:${value}`);

				p = de;
			}
			else {
				p = skip_at(b, p, t & 7);
			}
		}
	});

	return res;
}

// --- which source serves a category --------------------------------------------

// sources: [{ name, kind, enabled, index: { categories: {}, copied: [] } | null }]
// in configuration order. ref: from rules.geo_ref().
// Returns { source, file, cat, count, state: "ready" | "pending" } or { error }.
// "pending" means the category is known (or may exist) but is not in the
// trimmed file yet: the next data update downloads it.
export function resolve(sources, ref) {
	const check = (s) => {
		const idx = s.index;
		const r = { source: s.name, file: `${s.name}.dat`, cat: ref.cat, count: idx?.categories?.[ref.cat], state: 'pending' };

		if (idx && idx.categories?.[ref.cat] == null)
			return { error: `category "${ref.cat}" is not in geo source "${s.name}"` };

		if (idx && index(idx.copied ?? [], ref.cat) >= 0)
			r.state = 'ready';

		return r;
	};

	if (ref.source != null) {
		const s = filter(sources, (x) => x.name == ref.source)[0];

		if (!s)
			return { error: `geo source "${ref.source}" does not exist` };

		if (s.kind != ref.kind)
			return { error: `geo source "${ref.source}" holds ${s.kind}, not ${ref.kind}` };

		if (!s.enabled)
			return { error: `geo source "${ref.source}" is disabled` };

		return check(s);
	}

	const cands = filter(sources, (x) => x.kind == ref.kind && x.enabled);

	if (!length(cands))
		return { error: `there is no ${ref.kind} source` };

	for (let s in cands)
		if (s.index?.categories?.[ref.cat] != null)
			return check(s);

	// Not in any downloaded index: a source that was never downloaded may have it.
	for (let s in cands)
		if (!s.index)
			return check(s);

	return { error: `category "${ref.cat}" is not in any ${ref.kind} source` };
}

// Every geo reference in the rules of enabled sections.
export function refs(sections) {
	const out = [];

	for (let sec in sections ?? []) {
		if (!is_true(sec.enabled ?? '1'))
			continue;

		for (let d in entries(sec.domain)) {
			const r = norm_domain(d);

			if (r.geo)
				push(out, { section: sec['.name'], ref: r.geo, text: d });
		}

		for (let i in entries(sec.ip)) {
			const r = norm_ip(i);

			if (r.geo)
				push(out, { section: sec['.name'], ref: r.geo, text: i });
		}
	}

	return out;
}

// Categories each source has to keep in its trimmed file: { source: [cats] }.
export function wanted(sections, sources) {
	const res = {};

	for (let s in sources)
		res[s.name] = [];

	for (let r in refs(sections)) {
		const x = resolve(sources, r.ref);

		if (!x.error && index(res[x.source], x.cat) < 0)
			push(res[x.source], x.cat);
	}

	return res;
}
