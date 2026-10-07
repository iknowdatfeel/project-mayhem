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
bad() {
	printf 'FAIL %s\n' "$1"
	fail=1
	# On GitHub the failure also becomes an annotation of the run.
	if [ -n "${GITHUB_ACTIONS:-}" ]; then
		printf '::error title=%s::%s\n' "$(basename "$0")" "$(printf '%s' "$1" | awk 'BEGIN { ORS = "%0A" } { gsub(/%/, "%25"); print }')"
	fi
}

# constants must match between shell and ucode
for k in TPROXY_PORT DNS_PORT API_PORT METRICS_PORT HELPER_PORT FWMARK RT_TABLE NFT_TABLE RUN_DIR SUBS_DIR; do
	sh_v="$(sed -n "s/^MAYHEM_$k=//p" "$FILES/usr/share/mayhem/const.sh" | tr -d '"' | sed 's/^\${[A-Z_]*:-\(.*\)}$/\1/')"
	uc_v="$(sed -n "s/^export const $k = \(.*\);/\1/p" "$FILES/usr/share/ucode/mayhem/const.uc" | sed 's/.*?? //' | tr -d "'")"
	if [ "$sh_v" = "$uc_v" ]; then ok "const $k"; else bad "const $k: sh=$sh_v uc=$uc_v"; fi
done

if out="$(uc "$ROOT/tests/links.uc" 2>&1)"; then
	printf '%s\n' "$out"
	ok "links"
else
	bad "links: $out"
fi

# subscription responses
sub_check() {
	# $1 file, $2 jq-free expectation: substring that must appear in the output
	local out
	out="$(uc "$FILES/usr/share/mayhem/sub.uc" parse "$ROOT/tests/subs/$1" "$ROOT/tests/subs/headers.txt" 2>&1)"
	case "$out" in
		*"$2"*) ok "subscription $1" ;;
		*) bad "subscription $1: expected $2 in $out" ;;
	esac
}
sub_check b64.txt '"name": "NL Amsterdam"'
sub_check b64.txt '"skipped": 1'
sub_check b64.txt '"title": "Моя подписка"'
sub_check b64.txt '"limit": true'
sub_check plain.txt '"name": "US"'
sub_check xray.json '"name": "NL xray"'
sub_check clash.yaml 'not supported'

# configuration read from UCI, with a downloaded subscription
mkdir -p "$OUT/uci-subs"
cat > "$OUT/uci-subs/mysub.json" <<'JSON'
{ "nodes": [
  { "name": "A", "link": "ss://YWVzLTI1Ni1nY206cHc@1.2.3.4:8388#A" },
  { "name": "B", "link": "ss://YWVzLTI1Ni1nY206cHc@1.2.3.5:8388#B" } ] }
JSON
mkdir -p "$OUT/uci-run"
if ! out="$(MAYHEM_UCI_DIR="$ROOT/tests/uci" MAYHEM_SUBS_DIR="$OUT/uci-subs" \
	uc "$FILES/usr/share/mayhem/gen.uc" --out "$OUT/uci-run" 2>&1)"; then
	bad "config from UCI with a subscription: $out"
elif ! grep -q '"bal-main"' "$OUT/uci-run/xray.json"; then
	bad "config from UCI with a subscription: no balancer for the section"
elif ! out="$("$XRAY" run -test -c "$OUT/uci-run/xray.json" 2>&1)"; then
	bad "config from UCI with a subscription: $(printf '%s' "$out" | tail -n 5)"
else
	ok "config from UCI with a subscription"
fi

for m in "$ROOT"/tests/models/*.json; do
	name="$(basename "$m" .json)"
	expect="$(sed -n 's/.*"_expect": *"\([a-z]*\)".*/\1/p' "$m")"
	mkdir -p "$OUT/$name"

	if uc "$FILES/usr/share/mayhem/gen.uc" --model "$m" --out "$OUT/$name" 2>"$OUT/$name.log"; then
		[ "$expect" = fail ] && { bad "model $name: expected failure"; continue; }
	else
		[ "$expect" = fail ] && { ok "model $name fails as expected"; continue; }
		bad "model $name: generator failed: $(cat "$OUT/$name.log")"; continue
	fi

	if "$XRAY" run -test -c "$OUT/$name/xray.json" >"$OUT/$name.xray.log" 2>&1; then
		ok "model $name: xray accepts the config"
	else
		bad "model $name: xray rejects the config: $(tail -n 5 "$OUT/$name.xray.log")"
	fi

	if command -v nft >/dev/null 2>&1; then
		if out="$(nft -c -f "$OUT/$name/nft.conf" 2>&1)"; then
			ok "model $name: nftables ruleset"
		else
			bad "model $name: nftables ruleset: $out"
		fi
	fi
done

if command -v shellcheck >/dev/null 2>&1; then
	if out="$(shellcheck -s sh -f gcc -e SC1091,SC2034,SC3043,SC2086,SC2046,SC2317,SC2329 \
		"$FILES/usr/bin/mayhem" "$FILES/usr/libexec/mayhem/xray-run" "$FILES/usr/libexec/mayhem/scheduler" \
		"$FILES/etc/uci-defaults/90-mayhem" \
		"$FILES/usr/share/mayhem/lib.sh" "$FILES/usr/share/mayhem/const.sh" "$ROOT/install.sh" 2>&1)"; then
		ok "shellcheck"
	else
		bad "shellcheck: $out"
	fi
fi

if command -v node >/dev/null 2>&1; then
	for f in "$ROOT"/luci-app-mayhem/htdocs/luci-static/resources/view/mayhem/*.js; do
		{ echo '(function(){'; cat "$f"; echo '})'; } > "$OUT/check.js"
		if out="$(node --check "$OUT/check.js" 2>&1)"; then
			ok "syntax $(basename "$f")"
		else
			bad "syntax $(basename "$f"): $out"
		fi
	done
fi

if out="$(uc -e "loadfile('$ROOT/luci-app-mayhem/root/usr/share/rpcd/ucode/luci.mayhem')" 2>&1 >/dev/null)"; then
	ok "rpcd backend compiles"
else
	bad "rpcd backend compiles: $out"
fi

for f in "$ROOT"/luci-app-mayhem/root/usr/share/luci/menu.d/*.json "$ROOT"/luci-app-mayhem/root/usr/share/rpcd/acl.d/*.json; do
	uc -e "json(require('fs').readfile('$f'))" >/dev/null 2>&1 && ok "json $(basename "$f")" || bad "json $(basename "$f")"
done

rm -rf "$OUT"
[ "$fail" = 0 ] && echo "all tests passed" || echo "some tests failed"
exit "$fail"
