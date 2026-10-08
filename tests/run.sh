#!/bin/sh
# Off-device tests: link parser, config generator, xray and nftables validation,
# shell and LuCI syntax.  UCODE and XRAY may point to the binaries to use.
#   UCODE=ucode XRAY=/path/to/xray tests/run.sh
# Run it with the ucode OpenWrt ships, not only the latest: older ucode wants
# `;` after `export function f() {}` and has no `name() {}` object methods.
# JSMIN (LuCI's modules/luci-base/src/jsmin.c, built) enables the check that
# the minified JS of the package still means the same as the source.

set -u

ROOT="$(cd "$(dirname "$0")/.." && pwd)"
FILES="$ROOT/mayhem/files"
UCODE="${UCODE:-ucode}"
XRAY="${XRAY:-xray}"
OUT="$(mktemp -d)"
fail=0

# Generated and downloaded files of the tests stay in OUT. OUT/etc does not
# exist yet, like /etc/mayhem on a fresh router.
export MAYHEM_RUN_DIR="$OUT/run" MAYHEM_GEO_DIR="$OUT/etc/geo" MAYHEM_LISTS_DIR="$OUT/etc/lists" MAYHEM_TMP_DIR="$OUT"

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
for k in TPROXY_PORT DNS_PORT API_PORT METRICS_PORT HELPER_PORT FWMARK RT_TABLE TUN_MASK TUN_RULE_PRIO NFT_TABLE RUN_DIR SUBS_DIR GEO_DIR LISTS_DIR; do
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

# Servers without TLS: refused_by_xray() must agree with xray itself, or one
# such server keeps xray from starting (or a usable one gets dropped).
mkdir -p "$OUT/refusal"
if list="$(uc "$ROOT/tests/refusal.uc" "$OUT/refusal" 2>&1)"; then
	wrong=""
	while read -r file want what; do
		out="$("$XRAY" run -test -c "$file" 2>&1)"
		case "$out" in
			*"Configuration OK"*) got=0 ;;
			*"prohibited unless"*) got=1 ;;
			*) got="error: $(printf '%s' "$out" | tail -n 1)" ;;
		esac
		[ "$got" = "$want" ] || wrong="$wrong
  $what: xray $got, generator $want"
	done <<EOF
$list
EOF
	if [ -z "$wrong" ]; then ok "plaintext servers: same verdict as xray"; else bad "plaintext servers:$wrong"; fi
else
	bad "plaintext servers: $list"
fi

# A new server list goes into running xray without a restart: stable tags and
# a restart key without the servers.
if out="$(uc "$ROOT/tests/live.uc" 2>&1)"; then
	ok "new servers: stable tags and restart key"
else
	bad "new servers: $out"
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

# WireGuard/AmneziaWG configs and AmneziaVPN keys
if out="$(uc "$ROOT/tests/awg.uc" "$ROOT/tests/awg/client.conf" 2>&1)"; then
	printf '%s\n' "$out"
	ok "awg"
else
	bad "awg: $out"
fi

if command -v node >/dev/null 2>&1; then
	if out="$(node "$ROOT/tests/vpnkey.js" 2>&1)"; then
		ok "vpn:// keys"
	else
		bad "vpn:// keys: $out"
	fi
fi

# geo data: parser, trimmed files, and a configuration that uses categories
python3 "$ROOT/tests/geo/mkdat.py" "$OUT/geo"
head -c 5000 "$OUT/geo/geosite.dat" > "$OUT/geo/broken.dat"

if out="$(uc "$ROOT/tests/geo.uc" "$OUT/geo" 2>&1)"; then
	printf '%s\n' "$out"
	ok "geo"
else
	bad "geo: $out"
fi

mkdir -p "$OUT/geo-uci" "$OUT/geo-run"
cat > "$OUT/geo-uci/mayhem" <<EOF
config settings 'settings'
	option mode 'lists'
	list interface 'br-lan'

config geo 'geo'
	option update_via 'direct'

config geo_source 'site'
	option kind 'geosite'
	option url 'file://$OUT/geo/geosite.dat'

config geo_source 'ip'
	option kind 'geoip'
	option url '$OUT/geo/geoip.dat'

config section 'main'
	option type 'proxy'
	list link 'trojan://pw@de.example:443?sni=de.example#DE'
	list domain 'geosite:youtube'
	list ip 'geoip:telegram'
	list list_file '$OUT/geo/my.lst'

config section 'ru'
	option type 'exclusion'
	list domain 'geosite:site:gov'
	list ip 'geoip:ru'

config section 'nope'
	option type 'block'
	list domain 'geosite:no-such-category'
EOF
printf 'listed.test\n10.20.30.0/24\n' > "$OUT/geo/my.lst"

geo_uc() { MAYHEM_UCI_DIR="$OUT/geo-uci" uc "$@"; }

out="$(geo_uc "$FILES/usr/share/mayhem/update.uc" due 2>&1)"
rc=$?
if [ "$rc" = 3 ]; then
	ok "geo download from files"
else
	bad "geo download from files: exit code $rc: $out"
fi

if ! out="$(geo_uc "$FILES/usr/share/mayhem/gen.uc" --out "$OUT/geo-run" 2>&1)"; then
	bad "config with geo categories: $out"
elif ! grep -q '"ext:site.dat:youtube"' "$OUT/geo-run/xray.json" || ! grep -q '"ext:ip.dat:telegram"' "$OUT/geo-run/xray.json"; then
	bad "config with geo categories: no ext: rules in the xray config"
elif ! grep -q 'domain:listed.test' "$OUT/geo-run/xray.json"; then
	bad "config with geo categories: the list file was not used"
elif ! grep -q '45.0.0.6/32' "$OUT/geo-run/nft.conf"; then
	bad "config with geo categories: geoip:ru is not in the kernel bypass"
elif ! grep -q 'no-such-category' "$OUT/geo-run/status.json"; then
	bad "config with geo categories: no warning for an unknown category"
elif ! out="$(XRAY_LOCATION_ASSET="$MAYHEM_GEO_DIR" "$XRAY" run -test -c "$OUT/geo-run/xray.json" 2>&1)"; then
	bad "config with geo categories: $(printf '%s' "$out" | tail -n 3)"
elif command -v nft >/dev/null 2>&1 && ! out="$(nft -c -f "$OUT/geo-run/nft.conf" 2>&1)"; then
	bad "config with geo categories: nftables: $out"
else
	ok "config with geo categories"
fi

ls -l "$MAYHEM_GEO_DIR/site.dat" > "$OUT/before"
geo_uc "$FILES/usr/share/mayhem/update.uc" due >/dev/null 2>&1
rc=$?
ls -l "$MAYHEM_GEO_DIR/site.dat" > "$OUT/after"
if [ "$rc" = 0 ] && cmp -s "$OUT/before" "$OUT/after"; then
	ok "geo update is not repeated when nothing is due"
else
	bad "geo update repeated: exit code $rc"
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

# The user's case: one such server in a subscription next to a working one.
if grep -q '185.132.132.239\|tr.example.org' "$OUT/plaintext/xray.json" 2>/dev/null; then
	bad "model plaintext: refused servers are still in the xray config"
elif ! grep -q 'Backup 1' "$OUT/plaintext/status.json" 2>/dev/null; then
	bad "model plaintext: no warning about the skipped server"
else
	ok "model plaintext: refused servers are skipped with a warning"
fi

if command -v shellcheck >/dev/null 2>&1; then
	if out="$(shellcheck -s sh -f gcc -e SC1091,SC2034,SC3043,SC2086,SC2046,SC2317,SC2329 \
		"$FILES/usr/bin/mayhem" "$FILES/usr/libexec/mayhem/xray-run" "$FILES/usr/libexec/mayhem/scheduler" \
		"$FILES/etc/uci-defaults/90-mayhem" "$ROOT/tests/netns.sh" "$ROOT/tests/build-ucode.sh" \
		"$FILES/usr/share/mayhem/lib.sh" "$FILES/usr/share/mayhem/const.sh" "$ROOT/install.sh" 2>&1)"; then
		ok "shellcheck"
	else
		bad "shellcheck: $out"
	fi
fi

if command -v node >/dev/null 2>&1; then
	for f in "$ROOT"/luci-app-mayhem/htdocs/luci-static/resources/view/mayhem/*.js "$ROOT"/luci-app-mayhem/htdocs/luci-static/resources/mayhem/*.js; do
		{ echo '(function(){'; cat "$f"; echo '})'; } > "$OUT/check.js"
		if out="$(node --check "$OUT/check.js" 2>&1)"; then
			ok "syntax $(basename "$f")"
		else
			bad "syntax $(basename "$f"): $out"
		fi
	done

	# The package ships these files minified by LuCI's jsmin.
	if [ -n "${JSMIN:-}" ]; then
		if out="$(node "$ROOT/tests/jsmin.js" "$ROOT"/luci-app-mayhem/htdocs/luci-static/resources/view/mayhem/*.js \
			"$ROOT"/luci-app-mayhem/htdocs/luci-static/resources/mayhem/*.js 2>&1)"; then
			ok "JS survives jsmin"
		else
			bad "JS survives jsmin: $out"
		fi
	fi
elif [ -n "${JSMIN:-}" ]; then
	bad "JS survives jsmin: node is not installed"
fi

# every string of the LuCI app has a Russian translation, the template is current
if out="$(python3 "$ROOT/tools/i18n.py" check 2>&1)"; then
	ok "Russian translation is complete"
else
	bad "Russian translation: $out"
fi

cp "$ROOT/luci-app-mayhem/po/templates/mayhem.pot" "$OUT/mayhem.pot"
python3 "$ROOT/tools/i18n.py" pot >/dev/null
if cmp -s "$OUT/mayhem.pot" "$ROOT/luci-app-mayhem/po/templates/mayhem.pot"; then
	ok "translation template is current"
else
	bad "translation template was outdated: run tools/i18n.py pot and commit it"
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
