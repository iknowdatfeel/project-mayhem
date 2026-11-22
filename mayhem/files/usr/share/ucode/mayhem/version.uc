// Mayhem: versions of Mayhem and of xray, compared. One implementation for
// the rpcd plugin and the command line (mayhem, through ucode -e).
// "v0.27.2", "0.27.0-exp.3", "0.27.0_pre3" (the package's form of it): the
// numbers one by one, then a prerelease is older than its release.

'use strict';

export function parse_version(v) {
	let s = replace(v ?? '', /^v/, '');
	let pre = null;
	// POSIX expressions (no lazy .*? or (?:) groups): the suffix is
	// anchored at the end, so a greedy prefix is the same
	const m = match(s, /^(.*)(-exp\.?([0-9]+)|_pre([0-9]+))$/);

	if (m) {
		s = m[1];
		pre = int(m[3] || m[4]) || 0;
	}

	return { parts: map(split(s, /[.-]/), (x) => int(x) || 0), pre: pre };
};

// Is a newer than b?
export function version_newer(a, b) {
	const va = parse_version(a), vb = parse_version(b);
	const x = va.parts, y = vb.parts;

	for (let i = 0; i < max(length(x), length(y)); i++)
		if ((x[i] ?? 0) != (y[i] ?? 0))
			return (x[i] ?? 0) > (y[i] ?? 0);

	if (va.pre == null && vb.pre != null)
		return true;
	if (va.pre != null && vb.pre == null)
		return false;
	if (va.pre != null && vb.pre != null)
		return va.pre > vb.pre;

	return false;
};
