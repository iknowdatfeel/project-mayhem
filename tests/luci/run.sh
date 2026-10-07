#!/bin/sh
# Renders every LuCI page of Mayhem in headless Chromium against a fake ubus.
#   UCODE=ucode tests/luci/run.sh LUCI_SRC
# LUCI_SRC: checkout of github.com/openwrt/luci (luci-base and the bootstrap theme).

set -u

ROOT="$(cd "$(dirname "$0")/../.." && pwd)"
FILES="$ROOT/mayhem/files"
UCODE="${UCODE:-ucode}"
FIX="$(mktemp -d)"
trap 'rm -rf "$FIX"' EXIT

uc() {
	MAYHEM_UCI_DIR="$FIX/uci" MAYHEM_RUN_DIR="$FIX/run" MAYHEM_GEO_DIR="$FIX/geo" MAYHEM_LISTS_DIR="$FIX/lists" \
	MAYHEM_SUBS_DIR="$FIX/subs" MAYHEM_TMP_DIR="$FIX" \
		"$UCODE" -L "$FILES/usr/share/ucode/*.uc" ${UCODE_LIB:+-L "$UCODE_LIB"} "$@"
}

mkdir -p "$FIX/uci" "$FIX/run" "$FIX/geo" "$FIX/lists" "$FIX/subs" "$FIX/dat"
cp "$ROOT/tests/luci/uci/network" "$ROOT/tests/luci/uci/firewall" "$FIX/uci/"
sed "s#@FIX@#$FIX#g" "$ROOT/tests/luci/uci/mayhem.in" > "$FIX/uci/mayhem"
python3 "$ROOT/tests/geo/mkdat.py" "$FIX/dat"

cat > "$FIX/subs/mysub.json" <<'JSON'
{ "name": "mysub", "url": "http://example.invalid/sub", "updated": 1790000000, "format": "uri", "skipped": 1,
  "info": { "title": "Test sub", "userinfo": { "upload": 1000, "download": 5000000, "total": 100000000000, "expire": 1798761600 },
            "hwid": { "active": true, "limit": false, "not_supported": false } },
  "nodes": [ { "name": "NL 1", "link": "ss://YWVzLTI1Ni1nY206cHc@1.2.3.4:8388#NL 1" },
             { "name": "DE 2", "link": "ss://YWVzLTI1Ni1nY206cHc@1.2.3.5:8388#DE 2" } ] }
JSON

uc "$FILES/usr/share/mayhem/update.uc" geo --force >/dev/null
[ -s "$FIX/geo/site.json" ] || { echo "geo update failed"; exit 1; }
uc "$FILES/usr/share/mayhem/gen.uc" --out "$FIX/run" 2>/dev/null || { echo "generator failed"; exit 1; }
echo up > "$FIX/run/tunnel.awg"

UCODE="$UCODE" python3 "$ROOT/tests/luci/harness.py" "$1" "$FIX"
