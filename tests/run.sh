#!/bin/sh
# Off-device tests: link parser, config generator, xray and nftables validation,
# shell and LuCI syntax.  UCODE and XRAY may point to the binaries to use.
#   UCODE=ucode XRAY=/path/to/xray tests/run.sh

set -u

ROOT="$(cd "$(dirname "$0")/.." && pwd)"
FILES="$ROOT/mayhem/files"
UCODE="${UCODE:-ucode}"
XRAY="${XRAY:-xray}"
OUT="$(mktemp -d)"
fail=0

uc() { "$UCODE" -L "$FILES/usr/share/ucode/*.uc" ${UCODE_LIB:+-L "$UCODE_LIB"} "$@"; }
ok() { printf 'ok   %s\n' "$1"; }
bad() { printf 'FAIL %s\n' "$1"; fail=1; }

# constants must match between shell and ucode
for k in TPROXY_PORT DNS_PORT FWMARK RT_TABLE NFT_TABLE RUN_DIR; do
	sh_v="$(sed -n "s/^MAYHEM_$k=//p" "$FILES/usr/share/mayhem/const.sh" | tr -d '"')"
	uc_v="$(sed -n "s/^export const $k = \(.*\);/\1/p" "$FILES/usr/share/ucode/mayhem/const.uc" | tr -d "'")"
	[ "$sh_v" = "$uc_v" ] && ok "const $k" || bad "const $k: sh=$sh_v uc=$uc_v"
done

uc "$ROOT/tests/links.uc" && ok "links" || bad "links"

for m in "$ROOT"/tests/models/*.json; do
	name="$(basename "$m" .json)"
	expect="$(sed -n 's/.*"_expect": *"\([a-z]*\)".*/\1/p' "$m")"
	mkdir -p "$OUT/$name"

	if uc "$FILES/usr/share/mayhem/gen.uc" --model "$m" --out "$OUT/$name" 2>"$OUT/$name.log"; then
		[ "$expect" = fail ] && { bad "model $name: expected failure"; continue; }
	else
		[ "$expect" = fail ] && { ok "model $name fails as expected"; continue; }
		bad "model $name: generator failed"; cat "$OUT/$name.log"; continue
	fi

	if "$XRAY" run -test -c "$OUT/$name/xray.json" >"$OUT/$name.xray.log" 2>&1; then
		ok "model $name: xray accepts the config"
	else
		bad "model $name: xray rejects the config"; tail -n 5 "$OUT/$name.xray.log"
	fi

	if command -v nft >/dev/null 2>&1; then
		nft -c -f "$OUT/$name/nft.conf" && ok "model $name: nftables ruleset" || bad "model $name: nftables ruleset"
	fi
done

if command -v shellcheck >/dev/null 2>&1; then
	shellcheck -s sh -e SC1091,SC2034,SC3043,SC2086,SC2046,SC2329 \
		"$FILES/usr/bin/mayhem" "$FILES/usr/libexec/mayhem/xray-run" \
		"$FILES/usr/share/mayhem/lib.sh" "$FILES/usr/share/mayhem/const.sh" "$ROOT/install.sh" &&
		ok "shellcheck" || bad "shellcheck"
fi

if command -v node >/dev/null 2>&1; then
	for f in "$ROOT"/luci-app-mayhem/htdocs/luci-static/resources/view/mayhem/*.js; do
		{ echo '(function(){'; cat "$f"; echo '})'; } > "$OUT/check.js"
		node --check "$OUT/check.js" && ok "syntax $(basename "$f")" || bad "syntax $(basename "$f")"
	done
fi

for f in "$ROOT"/luci-app-mayhem/root/usr/share/luci/menu.d/*.json "$ROOT"/luci-app-mayhem/root/usr/share/rpcd/acl.d/*.json; do
	uc -e "json(require('fs').readfile('$f'))" >/dev/null 2>&1 && ok "json $(basename "$f")" || bad "json $(basename "$f")"
done

rm -rf "$OUT"
[ "$fail" = 0 ] && echo "all tests passed" || echo "some tests failed"
exit "$fail"
