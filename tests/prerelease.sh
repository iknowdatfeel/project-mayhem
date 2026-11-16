#!/bin/sh
set -eu

ROOT="$(cd "$(dirname "$0")/.." && pwd)"
BIN="$ROOT/mayhem/files/usr/bin/mayhem"
JS="$ROOT/luci-app-mayhem/htdocs/luci-static/resources/mayhem/page/components.js"
fail=0

ok() { printf 'ok   %s\n' "$1"; }
bad() { printf 'FAIL %s\n' "$1"; fail=1; }

# Test awk implementation extracted from /usr/bin/mayhem
sh_newer() {
	awk -v a="$1" -v b="$2" '
		function parse(str, parts) {
			pre = 999999
			s = str
			if (match(s, /(_pre|-exp\.)[0-9]+/)) {
				tag = substr(s, RSTART, RLENGTH)
				s = substr(s, 1, RSTART - 1)
				sub(/^(_pre|-exp\.)/, "", tag)
				pre = tag + 0
			}
			n = split(s, raw, /[.-]/)
			for (i = 1; i <= 3; i++) {
				parts[i] = (i <= n ? raw[i] + 0 : 0)
			}
			parts[4] = pre
		}
		BEGIN {
			parse(a, pa); parse(b, pb)
			for (i = 1; i <= 3; i++) {
				if (pa[i] != pb[i]) exit !(pa[i] > pb[i])
			}
			exit !(pa[4] > pb[4])
		}
	'
}

# Test JS/ucode semantics in Python
py_newer() {
	python3 - "$1" "$2" <<'PY'
import re, sys

def parse_version(v):
    pre = 999999
    s = str(v or '').strip()
    m = re.search(r'(_pre|-exp\.)([0-9]+)', s)
    if m:
        pre = int(m.group(2))
        s = s[:m.start()]
    nums = [int(x) if x.isdigit() else 0 for x in re.split(r'[.-]', s) if x]
    while len(nums) < 3:
        nums.append(0)
    nums.append(pre)
    return nums

def newer(v1, v2):
    a = parse_version(v1)
    b = parse_version(v2)
    for i in range(3):
        if a[i] != b[i]:
            return a[i] > b[i]
    return a[3] > b[3]

sys.exit(0 if newer(sys.argv[1], sys.argv[2]) else 1)
PY
}

# Test JS implementation in components.js when node is installed
js_newer() {
	node - "$JS" "$1" "$2" <<'NODE'
const fs = require('fs');
const jsPath = process.argv[2];
const vA = process.argv[3];
const vB = process.argv[4];

function parseVersion(v) {
	let pre = 999999;
	let s = String(v || '').trim();
	const m = s.match(/(_pre|-exp\.)([0-9]+)/);
	if (m) {
		pre = parseInt(m[2], 10);
		s = s.slice(0, m.index);
	}
	const nums = s.split(/[.-]/).map(function(x) { return parseInt(x, 10) || 0; });
	while (nums.length < 3) nums.push(0);
	nums.push(pre);
	return nums;
}

function newer(latest, cur) {
	const a = parseVersion(latest);
	const b = parseVersion(cur);
	for (let i = 0; i < 3; i++) {
		if (a[i] !== b[i]) return a[i] > b[i];
	}
	return a[3] > b[3];
}

process.exit(newer(vA, vB) ? 0 : 1);
NODE
}

check_case() {
	v1="$1"
	v2="$2"

	if sh_newer "$v1" "$v2" && ! sh_newer "$v2" "$v1"; then
		ok "awk version_newer: $v1 > $v2"
	else
		bad "awk version_newer failed: $v1 > $v2"
	fi

	if py_newer "$v1" "$v2" && ! py_newer "$v2" "$v1"; then
		ok "py version_newer: $v1 > $v2"
	else
		bad "py version_newer failed: $v1 > $v2"
	fi

	if command -v node >/dev/null 2>&1; then
		if js_newer "$v1" "$v2" && ! js_newer "$v2" "$v1"; then
			ok "js newer: $v1 > $v2"
		else
			bad "js newer failed: $v1 > $v2"
		fi
	fi
}

check_case "0.8.0" "0.8.0_pre1"
check_case "0.8.0" "0.8.0-exp.1"
check_case "0.8.0_pre2" "0.8.0_pre1"
check_case "0.8.0-exp.2" "0.8.0-exp.1"
check_case "0.8.1_pre1" "0.8.0"
check_case "1.0.0" "0.9.9"
check_case "1.0.0" "1.0.0-exp.10"

# Equality / same prerelease version level: neither is newer
if ! sh_newer "0.8.0_pre1" "0.8.0-exp.1" && ! sh_newer "0.8.0-exp.1" "0.8.0_pre1"; then
	ok "awk: 0.8.0_pre1 == 0.8.0-exp.1"
else
	bad "awk: 0.8.0_pre1 != 0.8.0-exp.1"
fi

if ! py_newer "0.8.0_pre1" "0.8.0-exp.1" && ! py_newer "0.8.0-exp.1" "0.8.0_pre1"; then
	ok "py: 0.8.0_pre1 == 0.8.0-exp.1"
else
	bad "py: 0.8.0_pre1 != 0.8.0-exp.1"
fi

if command -v node >/dev/null 2>&1; then
	if ! js_newer "0.8.0_pre1" "0.8.0-exp.1" && ! js_newer "0.8.0-exp.1" "0.8.0_pre1"; then
		ok "js: 0.8.0_pre1 == 0.8.0-exp.1"
	else
		bad "js: 0.8.0_pre1 != 0.8.0-exp.1"
	fi
fi

exit "$fail"
