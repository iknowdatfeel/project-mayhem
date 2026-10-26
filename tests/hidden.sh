#!/bin/sh
# Servers deleted from a subscription: the generator leaves them out, the
# rpcd methods keep and restore them, the update moves the old exclusions
# of a section into the subscription. UCODE points to the ucode to use.
#   UCODE=/opt/ucode-24.10/ucode tests/hidden.sh

set -u

ROOT="$(cd "$(dirname "$0")/.." && pwd)"
FILES="$ROOT/mayhem/files"
UCODE="${UCODE:-ucode}"
OUT="$(mktemp -d)"
fail=0

uc() { "$UCODE" -L "$FILES/usr/share/ucode/*.uc" "$@"; }
ok() { printf 'ok   %s\n' "$1"; }
bad() { printf 'FAIL %s\n' "$1"; fail=1; }

# The names the generator lists for the server list of a config.
names() {
	uc -e "
		const n = json(require('fs').readfile('$1/nodes.json'));
		print(join(',', map(n.sections.pool.nodes, (x) => x.name)));
	"
}

mkdir -p "$OUT/subs"
cat > "$OUT/subs/mysub.json" <<'JSON'
{ "nodes": [
  { "name": "A", "link": "ss://YWVzLTI1Ni1nY206cHc@1.2.3.4:8388#A" },
  { "name": "B (x).y", "link": "ss://YWVzLTI1Ni1nY206cHc@1.2.3.5:8388#B" },
  { "name": "C", "link": "ss://YWVzLTI1Ni1nY206cHc@1.2.3.6:8388#C" } ] }
JSON

config() {
	mkdir -p "$1"
	cat > "$1/mayhem" <<CFG
config settings 'settings'
	option enabled '1'
	option mode 'lists'
	list interface 'br-lan'

config dns 'dns'
	list remote 'https://1.1.1.1/dns-query'

config subscription 'mysub'
	option url 'http://example.invalid/sub'
$2
config pool 'pool'
	list subscription 'mysub'
	option select 'auto'
$3
config section 'main'
	option type 'proxy'
	list domain 'youtube.com'
CFG
}

gen() {
	MAYHEM_UCI_DIR="$1" MAYHEM_SUBS_DIR="$OUT/subs" uc "$FILES/usr/share/mayhem/gen.uc" --out "$2" 2>&1
}

# 1. The generator: deleted servers stay out, the rest stays.
config "$OUT/u1" "	list hidden 'A'
	list hidden 'B (x).y'" ""
if ! out="$(gen "$OUT/u1" "$OUT/r1")"; then
	bad "generator with deleted servers: $out"
elif [ "$(names "$OUT/r1")" = "C" ]; then
	ok "generator: deleted subscription servers stay out"
else
	bad "generator: servers are $(names "$OUT/r1"), expected C"
fi

config "$OUT/u2" "" ""
if ! out="$(gen "$OUT/u2" "$OUT/r2")"; then
	bad "generator without deleted servers: $out"
elif [ "$(names "$OUT/r2")" = "A,B (x).y,C" ]; then
	ok "generator: nothing deleted, every server is there"
else
	bad "generator: servers are $(names "$OUT/r2"), expected A,B (x).y,C"
fi

# A regular expression of the subscription leaves servers out by name.
config "$OUT/u4" "	option exclude '^b|^X\$'" ""
if ! out="$(gen "$OUT/u4" "$OUT/r4")"; then
	bad "generator with a subscription exclude: $out"
elif [ "$(names "$OUT/r4")" = "A,C" ]; then
	ok "generator: servers matching the subscription's expression stay out"
else
	bad "generator: servers are $(names "$OUT/r4"), expected A,C"
fi

# 2. server_delete and server_restore.
config "$OUT/u3" "" ""
if out="$(MAYHEM_UCI_DIR="$OUT/u3" MAYHEM_RUN_DIR="$OUT/run3" uc "$ROOT/tests/hidden.uc" \
	"$ROOT/luci-app-mayhem/root/usr/share/rpcd/ucode/luci.mayhem" 2>&1)"; then
	ok "deleting and restoring subscription servers"
else
	bad "deleting and restoring subscription servers: $out"
fi

# 3. The update moves the old ^name$ exclusions of a section.
config "$OUT/u4" "" "	option exclude '^A\$|^B \\(x\\)\\.y\$|^gone\$|C.*'"
if ! out="$(MAYHEM_UCI_DIR="$OUT/u4" MAYHEM_SUBS_DIR="$OUT/subs" uc "$FILES/usr/share/mayhem/migrate.uc" 2>&1)"; then
	bad "old exclusions: migrate.uc failed: $out"
else
	res="$(uc -e "
		const c = require('uci').cursor('$OUT/u4');
		c.load('mayhem');
		print(join(',', c.get('mayhem', 'mysub', 'hidden') ?? []), '|', c.get('mayhem', 'pool', 'exclude') ?? '');
	")"
	if [ "$res" = 'A,B (x).y|^gone$|C.*' ]; then
		ok "old exclusions move into the subscription; unknown names and real expressions stay"
	else
		bad "old exclusions: got '$res'"
	fi
fi

rm -rf "$OUT"
exit "$fail"
