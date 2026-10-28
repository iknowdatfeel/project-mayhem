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
# xray opens its connection log (in the run directory) even with run -test.
mkdir -p "$MAYHEM_RUN_DIR"

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

# Mux: Vision servers (flat or "vnext" form) get UDP only, XHTTP none.
if out="$(uc "$ROOT/tests/mux.uc" 2>&1)"; then
	ok "mux by flow and transport"
else
	bad "mux: $out"
fi

# Block sections: spelled-out domains refused by dnsmasq, the rest in xray.
if out="$(uc "$ROOT/tests/block.uc" 2>&1)"; then
	ok "block sections in dnsmasq"
else
	bad "block: $out"
fi

# Rules and DNS servers as written: a regexp keeps its commas, a DNS port is a port.
if out="$(uc "$ROOT/tests/entries.uc" 2>&1)"; then
	ok "entries: regexp with commas, DNS ports"
else
	bad "entries: $out"
fi

# Several DNS servers: fallback with a short timeout each, parallel on request.
if out="$(uc "$ROOT/tests/dnsrow.uc" 2>&1)"; then
	ok "DNS servers in a row"
else
	bad "DNS servers in a row: $out"
fi

# The router's own TCP through xray: marks, chain output, nftables syntax.
if ! out="$(uc "$ROOT/tests/router.uc" "$OUT/router.nft" 2>&1)"; then
	bad "router traffic through xray: $out"
elif command -v nft >/dev/null 2>&1 && ! out="$(nft -c -f "$OUT/router.nft" 2>&1)"; then
	bad "router traffic through xray: nftables: $out"
else
	ok "router traffic through xray"
fi

# TCP ping on the dashboard: one timeout per silent host, a budget per call.
if out="$(uc "$ROOT/tests/ping.uc" 2>&1)"; then
	ok "TCP ping: shared checks, a silent host waited for once"
else
	bad "TCP ping: $out"
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
# nftset support of dnsmasq: a plain build says "no-nftset" (OpenWrt's
# dnsmasq), which must not count, or dnsmasq refuses Mayhem's config.
if uc "$ROOT/tests/nftset.uc" 2>/dev/null; then
	ok "dnsmasq nftset support: no-nftset does not count"
else
	bad "dnsmasq nftset support: no-nftset is taken for nftset"
fi

# The same check in the shell (mayhem dnsmasq-full uses it).
mkdir -p "$OUT/dnsm/plain" "$OUT/dnsm/full"
printf '#!/bin/sh\necho "Compile time options: IPv6 GNU-getopt no-DBus UBus no-ipset no-nftset no-auth"\n' > "$OUT/dnsm/plain/dnsmasq"
printf '#!/bin/sh\necho "Compile time options: IPv6 GNU-getopt no-DBus UBus no-ipset nftset auth"\n' > "$OUT/dnsm/full/dnsmasq"
chmod +x "$OUT/dnsm/plain/dnsmasq" "$OUT/dnsm/full/dnsmasq"
nftset_sh() {
	PATH="$OUT/dnsm/$1:$PATH" MAYHEM_LIB_DIR="$FILES/usr/share/mayhem" sh -c \
		'. "$MAYHEM_LIB_DIR/lib.sh"; mayhem_dnsmasq_nftset && echo yes || echo no'
}
if [ "$(nftset_sh plain)" = no ] && [ "$(nftset_sh full)" = yes ]; then
	ok "dnsmasq-full install: plain dnsmasq is not taken for dnsmasq-full"
else
	bad "dnsmasq-full install: plain=$(nftset_sh plain) full=$(nftset_sh full)"
fi

# A tunnel in the server list is one of its servers (chosen on the dashboard).
pool_tunnel_check() {
	mkdir -p "$OUT/uci-pooltun"
	sed "s/^config pool 'pool'$/config pool 'pool'\n\tlist iface_node 'awg0'/" "$OUT/uci-pool/mayhem" > "$OUT/uci-pooltun/mayhem"
	if ! out="$(MAYHEM_UCI_DIR="$OUT/uci-pooltun" MAYHEM_SUBS_DIR="$OUT/uci-subs" \
		uc "$FILES/usr/share/mayhem/gen.uc" --out "$OUT/uci-pooltun-run" 2>&1)"; then
		bad "tunnel in the server list: $out"
	elif ! uc -e "
		const x = json(require('fs').readfile('$OUT/uci-pooltun-run/xray.json'));
		const t = filter(x.outbounds, (o) => match(o.tag, /^n-pool-/) && o.streamSettings?.sockopt?.interface == 'awg0');
		const n = json(require('fs').readfile('$OUT/uci-pooltun-run/nodes.json'));
		const names = map(n.sections.pool.nodes, (x) => x.name);
		exit((length(t) == 1 && index(names, 'awg0') >= 0) ? 0 : 1);
	" 2>/dev/null; then
		bad "tunnel in the server list: awg0 is not one of its servers"
	elif ! out="$("$XRAY" run -test -c "$OUT/uci-pooltun-run/xray.json" 2>&1)"; then
		bad "tunnel in the server list: $(printf '%s' "$out" | tail -n 5)"
	else
		ok "tunnel in the server list is one of its servers"
	fi
}

# A fallback chain keeps whole server names: they may have spaces and commas.
pool_chain_check() {
	mkdir -p "$OUT/uci-poolchain"
	sed "s/^config pool 'pool'$/config pool 'pool'\n\tlist link 'ss:\/\/YWVzLTI1Ni1nY206cHc@1.2.3.10:8388#NL fast, 1'\n\tlist link 'ss:\/\/YWVzLTI1Ni1nY206cHc@1.2.3.11:8388#Backup hy2'\n\toption select 'fallback'\n\tlist chain 'Backup hy2'\n\tlist chain 'NL fast, 1'/; /^\toption select 'auto'$/d" \
		"$OUT/uci-pool/mayhem" > "$OUT/uci-poolchain/mayhem"
	if ! out="$(MAYHEM_UCI_DIR="$OUT/uci-poolchain" MAYHEM_SUBS_DIR="$OUT/uci-subs" \
		uc "$FILES/usr/share/mayhem/gen.uc" --out "$OUT/uci-poolchain-run" 2>&1)"; then
		bad "fallback chain: $out"
	elif printf '%s' "$out" | grep -q "fallback chain is gone"; then
		bad "fallback chain: $(printf '%s' "$out" | grep "fallback chain")"
	elif ! uc -e "
		const s = json(require('fs').readfile('$OUT/uci-poolchain-run/nodes.json')).sections.pool;
		const name = (t) => filter(s.nodes, (n) => n.tag == t)[0]?.name;
		exit((s.mode == 'fallback' && join('|', map(s.chain, name)) == 'Backup hy2|NL fast, 1' && name(s.selected) == 'Backup hy2') ? 0 : 1);
	" 2>/dev/null; then
		bad "fallback chain: not the two servers in their order"
	else
		ok "fallback chain with spaces and commas in server names"
	fi
}

# Comments and text around the keys are not servers; base64 may be wrapped.
sub_check mixed-b64.txt '"name": "A server"'
sub_check mixed-b64.txt '"skipped": 0'
# A web page instead of the file (a GitHub file page, a login page).
sub_check page.html 'web page'
sub_check error.json 'the server answered: Not Found'

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

# Migration to the server list: the main section's servers move into it, the
# section keeps its rules and uses the list; then a section without servers of
# its own goes through the list's active server.
mkdir -p "$OUT/uci-pool"
cp "$ROOT/tests/uci/mayhem" "$OUT/uci-pool/mayhem"
cat >> "$OUT/uci-pool/mayhem" <<'UCI'
	list link 'ss://YWVzLTI1Ni1nY206cHc@1.2.3.9:8388#Own'

config subscription 'other'
	option url 'http://example.invalid/other'
	option enabled '0'

config section 'video'
	option type 'proxy'
	list domain 'example.org'
UCI
if ! out="$(MAYHEM_UCI_DIR="$OUT/uci-pool" uc "$FILES/usr/share/mayhem/migrate.uc" 2>&1)"; then
	bad "migration to the server list: $out"
elif ! grep -q "config pool 'pool'" "$OUT/uci-pool/mayhem" || ! grep -A3 "config pool" "$OUT/uci-pool/mayhem" | grep -q "1.2.3.9" ||
	! grep -A6 "config section 'main'" "$OUT/uci-pool/mayhem" | grep -q "servers 'pool'" ||
	grep -A6 "config section 'main'" "$OUT/uci-pool/mayhem" | grep -q "list subscription"; then
	bad "migration to the server list: $(cat "$OUT/uci-pool/mayhem")"
elif ! out="$(MAYHEM_UCI_DIR="$OUT/uci-pool" uc "$FILES/usr/share/mayhem/migrate.uc" 2>&1)" || [ "$out" != "nothing to do" ]; then
	bad "migration to the server list runs twice: $out"
elif ! out="$(MAYHEM_UCI_DIR="$OUT/uci-pool" MAYHEM_SUBS_DIR="$OUT/uci-subs" \
	uc "$FILES/usr/share/mayhem/gen.uc" --out "$OUT/uci-pool-run" 2>&1)"; then
	bad "server list: $out"
elif ! uc -e "
	const x = json(require('fs').readfile('$OUT/uci-pool-run/xray.json'));
	const tags = map(filter(x.outbounds, (o) => match(o.tag, /^n-pool-/)), (o) => o.tag);
	const rules = filter(x.routing.rules, (r) => r.balancerTag == 'bal-pool' && length(r.domain ?? []));
	const doms = [];
	for (let r in rules) push(doms, ...r.domain);
	exit((length(tags) == 3 && index(doms, 'domain:youtube.com') >= 0 && index(doms, 'domain:example.org') >= 0) ? 0 : 1);
" 2>/dev/null; then
	bad "server list: sections without servers do not use it"
elif ! out="$("$XRAY" run -test -c "$OUT/uci-pool-run/xray.json" 2>&1)"; then
	bad "server list: $(printf '%s' "$out" | tail -n 5)"
else
	ok "server list: migration, sections without servers, subscriptions"
fi
pool_tunnel_check
pool_chain_check

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
elif grep -q '"ext:ip.dat:ru"' "$OUT/geo-run/xray.json"; then
	bad "config with geo categories: geoip:ru of a direct section is in xray as well (the kernel has it)"
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

# A geoip file added with the type geosite: the type is taken from the file and
# the categories are picked again for it.
mkdir -p "$OUT/geo-kind/uci" "$OUT/geo-kind/geo" "$OUT/geo-kind/run"
cat > "$OUT/geo-kind/uci/mayhem" <<EOF
config geo_source 'ip2'
	option kind 'geosite'
	option url '$OUT/geo/geoip.dat'

config section 'main'
	option type 'proxy'
	list link 'trojan://pw@de.example:443?sni=de.example#DE'
	list ip 'geoip:ip2:telegram'
EOF
out="$(MAYHEM_UCI_DIR="$OUT/geo-kind/uci" MAYHEM_GEO_DIR="$OUT/geo-kind/geo" MAYHEM_RUN_DIR="$OUT/geo-kind/run" \
	uc "$FILES/usr/share/mayhem/update.uc" geo ip2 --force 2>&1)"
if ! grep -q "option kind 'geoip'" "$OUT/geo-kind/uci/mayhem"; then
	bad "geo source type from the file: the type stayed geosite: $out"
elif ! grep -q '"telegram"' "$OUT/geo-kind/geo/ip2.json"; then
	bad "geo source type from the file: geoip:ip2:telegram was not kept: $out"
else
	ok "geo source type from the file"
fi

# The same category in a geoip and a geosite file (Re:filter: "refilter" in
# both), the geoip one added as geosite and listed first: once its type is
# fixed, the geosite file keeps the category in the same update.
mkdir -p "$OUT/geo-both/uci" "$OUT/geo-both/geo" "$OUT/geo-both/run" "$OUT/geo-both/dat"
python3 -c "
import sys; sys.path.insert(0, '$ROOT/tests/geo'); import mkdat
open('$OUT/geo-both/dat/geoip.dat', 'wb').write(mkdat.geoip([('BOTH', ['45.0.0.9/32']), ('PRIVATE', ['10.0.0.0/8'])]))
open('$OUT/geo-both/dat/geosite.dat', 'wb').write(mkdat.geosite([('BOTH', ['domain:both.test'])]))
"
cat > "$OUT/geo-both/uci/mayhem" <<EOF
config geo_source 'rf_ip'
	option kind 'geosite'
	option url '$OUT/geo-both/dat/geoip.dat'

config geo_source 'rf_site'
	option kind 'geosite'
	option url '$OUT/geo-both/dat/geosite.dat'

config section 'main'
	option type 'proxy'
	list link 'trojan://pw@de.example:443?sni=de.example#DE'
	list ip 'geoip:both'
	list domain 'geosite:both'
EOF
out="$(MAYHEM_UCI_DIR="$OUT/geo-both/uci" MAYHEM_GEO_DIR="$OUT/geo-both/geo" MAYHEM_RUN_DIR="$OUT/geo-both/run" \
	uc "$FILES/usr/share/mayhem/update.uc" geo --force 2>&1)"
if uc -e "
	const c = (f) => json(require('fs').readfile('$OUT/geo-both/geo/' + f + '.json')).copied;
	exit(index(c('rf_ip'), 'both') >= 0 && index(c('rf_site'), 'both') >= 0 ? 0 : 1);
" 2>/dev/null; then
	ok "a category in both kinds of file: kept in each after the type is fixed"
else
	bad "a category in both kinds of file: $out"
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

# Memory: direct UDP leaves through an outbound with a short idle timeout,
# servers are checked one at a time over the interval, the config is compact.
if ! uc -e "
	const x = json(require('fs').readfile('$OUT/lists/xray.json'));
	const du = filter(x.outbounds, (o) => o.tag == 'direct-udp')[0];
	const lvl = du?.settings?.userLevel;
	const r = x.routing.rules;
	const fin = filter(r, (q) => q.network == 'tcp,udp' && q.inboundTag?.[0] == 'tproxy-in');
	const udp = filter(r, (q) => q.network == 'udp' && q.outboundTag == 'direct-udp');
	exit((du && lvl && x.policy.levels[sprintf('%d', lvl)]?.connIdle < 300 && length(fin) == 1 && length(udp) == 1 &&
		index(r, udp[0]) == index(r, fin[0]) - 1 && fin[0].outboundTag == 'direct') ? 0 : 1);
" 2>/dev/null; then
	bad "model lists: direct UDP does not leave through direct-udp"
elif ! uc -e "
	const x = json(require('fs').readfile('$OUT/global/xray.json'));
	const r = x.routing.rules;
	const fin = filter(r, (q) => q.network == 'tcp,udp' && q.inboundTag?.[0] == 'tproxy-in')[0];
	const torrent = filter(r, (q) => q.protocol?.[0] == 'bittorrent' && q.network == 'udp')[0];
	exit((fin?.balancerTag && r[index(r, fin) - 1].outboundTag != 'direct-udp' && torrent?.outboundTag == 'direct-udp') ? 0 : 1);
" 2>/dev/null; then
	bad "model global: the rest of the UDP must go through the proxy, torrent UDP through direct-udp"
elif ! uc -e "
	const x = json(require('fs').readfile('$OUT/subs/xray.json'));
	const b = x.burstObservatory;
	exit((x.observatory == null && b?.pingConfig?.sampling == 1 && length(b.subjectSelector) > 0) ? 0 : 1);
" 2>/dev/null; then
	bad "model subs: servers are not checked one at a time (burstObservatory)"
elif [ "$(wc -l < "$OUT/lists/xray.json")" != 1 ]; then
	bad "model lists: xray.json is not compact"
elif ! uc -e "
	const d = json(require('fs').readfile('$OUT/lists/xray.json')).dns;
	exit((d.serveStale === true && d.serveExpiredTTL > 0) ? 0 : 1);
" 2>/dev/null; then
	bad "model lists: an expired DNS answer is not served while it is renewed (serveStale)"
else
	ok "memory: direct UDP idle timeout, spread server checks, compact config; stale DNS answers"
fi

# The rest of the traffic into a kernel tunnel (main section, global mode):
# exclusions and blocked domains stay out of it, proxy sections still reach
# xray, everything else gets the tunnel's mark before xray.
nft_rest() {
	# $1 model dir: line numbers of the rules, "-" when missing
	for re in '@blk_d4 meta mark set' '@direct4 counter return' '@dir_d4 counter return' '@px_d4 meta l4proto' \
		'meta nfproto ipv4 meta l4proto tcp th dport { 80, 443 } meta mark set meta mark & 0x[0-9a-f]* | 0x4000001 \(ct mark set ct mark & 0x[0-9a-f]* | 0x[0-9a-f]* \)\?counter return' \
		'meta nfproto ipv4 meta l4proto { tcp, udp } meta mark set meta mark | 0x2000000 .*tproxy'; do
		n="$(grep -n -- "$re" "$1/nft.conf" | head -n 1 | cut -d: -f1)"
		printf '%s ' "${n:--}"
	done
}
set -- $(nft_rest "$OUT/tunrest")
if [ "$#" != 6 ] || [ "$1" = - ] || [ "$2" = - ] || [ "$3" = - ] || [ "$4" = - ] || [ "$5" = - ] || [ "$6" = - ] || \
   [ "$1" -gt "$2" ] || [ "$2" -gt "$3" ] || [ "$3" -gt "$4" ] || [ "$4" -gt "$5" ] || [ "$5" -gt "$6" ]; then
	bad "model tunrest: rules out of order (block, direct, exclusions, proxy, tunnel, xray): $*"
elif ! grep -q 'nftset=/ru.test/yandex.test/.*#dir_d4' "$OUT/tunrest/dnsmasq.conf" || \
     ! grep -q 'nftset=/instagram.com/.*#px_d4' "$OUT/tunrest/dnsmasq.conf" || \
     ! grep -q 'nftset=/ads.test/.*#blk_d4' "$OUT/tunrest/dnsmasq.conf"; then
	bad "model tunrest: dnsmasq does not fill the sets: $(cat "$OUT/tunrest/dnsmasq.conf")"
elif grep -q 'meta nfproto ipv6 .*| 0x4000001' "$OUT/tunrest/nft.conf"; then
	bad "model tunrest: IPv6 goes into a tunnel without IPv6"
elif grep -q 'meta nfproto ipv4 meta mark set meta mark & 0x[0-9a-f]* | 0x4000001' "$OUT/tunrest/nft.conf" || \
     ! grep -q 'meta nfproto ipv4 meta l4proto udp th dport 443 meta mark set' "$OUT/tunrest/nft.conf"; then
	bad "model tunrest: with torrents direct only web traffic may go into the tunnel in the kernel"
elif ! grep -q 'meta l4proto udp th dport 443 meta mark set meta mark | 0x8000000 counter return' "$OUT/tunrest/nft.conf" || \
     grep -q 'udp th dport 443 meta mark set meta mark | 0x8000000' "$OUT/tunrest-fake/nft.conf"; then
	bad "model tunrest: QUIC off must drop UDP 443 before the tunnel, and only then"
elif ! grep -q 'meta nfproto ipv4 meta mark set meta mark & 0x[0-9a-f]* | 0x4000001 \(ct mark set ct mark & 0x[0-9a-f]* | 0x[0-9a-f]* \)\?counter return' "$OUT/tunrest-fake/nft.conf"; then
	bad "model tunrest-fake: without torrents direct all the rest goes into the tunnel in the kernel"
elif grep -q '#px_d4' "$OUT/tunrest-fake/dnsmasq.conf" || ! grep -q '198.18.0.0/15 meta l4proto' "$OUT/tunrest-fake/nft.conf" || \
     ! uc -e "
	const x = json(require('fs').readfile('$OUT/tunrest-fake/xray.json'));
	const f = filter(x.dns.servers, (s) => s.address == 'fakedns');
	exit((length(f) == 1 && index(f[0].domains, 'domain:instagram.com') >= 0) ? 0 : 1);
" 2>/dev/null; then
	bad "model tunrest-fake: FakeDNS must answer only proxy domains, its pool goes to xray"
elif grep -q 'px_4\|0x4000001.*counter return$' "$OUT/global/nft.conf" 2>/dev/null; then
	bad "model global: the rest goes into a tunnel without a tunnel main section"
else
	ok "the rest of the traffic into a kernel tunnel: exclusions, blocking and proxy sections kept"
fi

# Connections carry the generation of their path; picking a tunnel for the
# rest (or leaving it) changes it, and connections of the old one are reset
# instead of hanging (Telegram waited minutes for answers that never came).
gen_of() { grep -o 'ct mark set ct mark & 0x[0-9a-f]* | 0x[0-9a-f]*' "$1" | awk '{ print $NF }' | sort -u; }
if [ "$(gen_of "$OUT/global/nft.conf")" != 0x10000000 ] || [ -z "$(gen_of "$OUT/pooltun/nft.conf")" ] ||
   [ "$(gen_of "$OUT/pooltun/nft.conf")" = 0x10000000 ] || [ "$(gen_of "$OUT/pooltun/nft.conf" | wc -l)" != 1 ]; then
	bad "path generation: global $(gen_of "$OUT/global/nft.conf" | tr '\n' ' '), picked tunnel $(gen_of "$OUT/pooltun/nft.conf" | tr '\n' ' ')"
elif ! grep -q 'ct state established,related ct mark & 0x30000000 != 0 ct mark & 0x30000000 != 0x10000000 meta mark set meta mark | 0x8000000 counter return' "$OUT/global/nft.conf" ||
     ! grep -q 'meta mark & 0x8000000 == 0x8000000 meta l4proto tcp counter reject with tcp reset' "$OUT/global/nft.conf"; then
	bad "connections of an old path are not reset"
else
	ok "connections of an old path are reset when the main server becomes or stops being a kernel tunnel"
fi

# A tunnel picked by hand in the server list takes the rest in the kernel;
# the watchdog keeps the choice (bal 0). Without dnsmasq-full it stays in xray.
if ! grep -q 'meta nfproto ipv4 meta mark set meta mark & 0x[0-9a-f]* | 0x4000001 \(ct mark set ct mark & 0x[0-9a-f]* | 0x[0-9a-f]* \)\?counter return' "$OUT/pooltun/nft.conf" 2>/dev/null ||
   ! grep -q '^pool awg0 0x4000001 111 0 0$' "$OUT/pooltun/tunnels" 2>/dev/null ||
   ! grep -q 'nftset=/ru.test/.*#dir_d4' "$OUT/pooltun/dnsmasq.conf" 2>/dev/null; then
	bad "model pooltun: the picked tunnel does not take the rest in the kernel: $(cat "$OUT/pooltun/tunnels" 2>/dev/null)"
elif grep -q '0x4000001' "$OUT/pooltun-plain/nft.conf" 2>/dev/null || ! grep -q 'with dnsmasq-full it would go in the kernel' "$OUT/pooltun-plain/status.json"; then
	bad "model pooltun-plain: without dnsmasq-full the tunnel must stay in xray, with a hint"
elif ! uc -e "
	const n = json(require('fs').readfile('$OUT/pooltun/nodes.json'));
	const t = filter(n.sections.pool.nodes, (x) => x.iface == 'awg0')[0];
	exit((n.sections.pool.kernel == 'awg0' && t?.tproto == 'amneziawg' && t?.device == 'awg0') ? 0 : 1);
" 2>/dev/null; then
	bad "model pooltun: nodes.json does not tell the dashboard about the kernel tunnel"
else
	ok "a tunnel picked in the server list takes the rest in the kernel"
fi

# A kernel tunnel section does not hand dnsmasq more domains than it can hold.
cat > "$OUT/bigtun.json" <<'JSON'
{ "settings": { "mode": "lists", "interface": ["br-lan"] },
  "dns": { "remote": ["https://1.1.1.1/dns-query"] },
  "geo": { "sources": [ { "name": "site", "kind": "geosite", "enabled": true,
    "index": { "categories": { "huge": 1400000, "small": 2 }, "copied": ["huge", "small"] } } ],
    "domains": { "site:small": ["domain:a.test", "full:b.test"] } },
  "sections": [ { ".name": "awg", "type": "interface", "enabled": "1", "interface": "awg0",
    "domain": ["geosite:huge", "geosite:small"] } ],
  "runtime": { "wan_dns": ["192.168.100.1"], "ipv6": false, "dnsmasq_nftset": true,
    "ifaces": { "awg0": { "device": "awg0", "up": true, "v6": false } } } }
JSON
mkdir -p "$OUT/bigtun"
if ! uc "$FILES/usr/share/mayhem/gen.uc" --model "$OUT/bigtun.json" --out "$OUT/bigtun" 2>/dev/null; then
	bad "huge category in a kernel tunnel: generator failed"
elif ! grep -q 'too many for dnsmasq' "$OUT/bigtun/status.json" || ! grep -q '/a.test/b.test/' "$OUT/bigtun/dnsmasq.conf"; then
	bad "huge category in a kernel tunnel: no warning, or the small category is lost: $(cat "$OUT/bigtun/dnsmasq.conf")"
else
	ok "huge category in a kernel tunnel goes through xray, small ones through dnsmasq"
fi

# Global mode: excluded domains go direct in the kernel (their addresses come
# from dnsmasq), not through xray, with FakeDNS or without; an address another
# site also has goes to xray. Not without nftset in dnsmasq.
gdir() {
	# $1 name, $2 fakedns, $3 dnsmasq_nftset; prints "nft dnsmasq" counts
	cat > "$OUT/gdir-$1.json" <<JSON
{ "settings": { "mode": "global", "default_section": "main", "interface": ["br-lan"] },
  "dns": { "remote": ["https://1.1.1.1/dns-query"], "fakedns": "$2" },
  "sections": [
    { ".name": "main", "type": "proxy", "enabled": "1", "link": "socks://1.2.3.4:1080" },
    { ".name": "ru", "type": "exclusion", "enabled": "1", "domain": ["gosuslugi.test", "keyword:bank"], "ip": ["45.0.0.6"] } ],
  "runtime": { "wan_dns": ["192.168.100.1"], "ipv6": false, "dnsmasq_nftset": $3 } }
JSON
	mkdir -p "$OUT/gdir-$1"
	uc "$FILES/usr/share/mayhem/gen.uc" --model "$OUT/gdir-$1.json" --out "$OUT/gdir-$1" 2>/dev/null || { echo fail; return; }
	echo "$(grep -c '@dir_d4 ip daddr != @oth_d4 counter return' "$OUT/gdir-$1/nft.conf") $(grep -c 'nftset=/gosuslugi.test/4#inet#mayhem#dir_d4\|nftset=/#/4#inet#mayhem#oth_d4' "$OUT/gdir-$1/dnsmasq.conf")"
}
got="$(gdir fake 1 true) / $(gdir real 0 true) / $(gdir plain 1 false)"
if [ "$got" = "1 2 / 1 2 / 0 0" ]; then
	ok "global mode: excluded domains go direct in the kernel with dnsmasq-full, FakeDNS or not"
else
	bad "global mode, excluded domains in the kernel: got $got, want 1 2 / 1 2 / 0 0"
fi

# Firmware version, target and package arch for the AmneziaWG builds.
# `ubus call system board` has no arch, so it must come from the release file.
mkdir -p "$OUT/fw/bin"
cat > "$OUT/fw/openwrt_release" <<'EOF'
DISTRIB_ID='OpenWrt'
DISTRIB_RELEASE='25.12.5'
DISTRIB_TARGET='mediatek/filogic'
DISTRIB_ARCH='aarch64_cortex-a53'
EOF
cat > "$OUT/fw/bin/ubus" <<'EOF'
#!/bin/sh
echo '{"release":{"distribution":"OpenWrt","version":"24.10.8","target":"ramips/mt7621"}}'
EOF
printf '#!/bin/sh\necho mipsel_24kc\n' > "$OUT/fw/bin/apk"
printf '#!/bin/sh\nexit 1\n' > "$OUT/fw/bin/jsonfilter"
chmod +x "$OUT/fw/bin/ubus" "$OUT/fw/bin/apk" "$OUT/fw/bin/jsonfilter"
fw_info() {
	# $1 release file; prints "version target arch" or "fail"
	PATH="$OUT/fw/bin:$PATH" MAYHEM_LIB_DIR="$FILES/usr/share/mayhem" MAYHEM_RELEASE_FILE="$1" sh -c \
		'. "$MAYHEM_LIB_DIR/lib.sh"; if mayhem_fw_release; then echo "$FW_VERSION $FW_TARGET $FW_ARCH"; else echo fail; fi'
}
got="$(fw_info "$OUT/fw/openwrt_release")"
if [ "$got" = "25.12.5 mediatek/filogic aarch64_cortex-a53" ]; then
	ok "firmware version, target and arch from the release file"
else
	bad "firmware version, target and arch from the release file: $got"
fi
# without the release file: version and target from ubus, arch from apk
cat > "$OUT/fw/bin/jsonfilter" <<'EOF'
#!/bin/sh
key="${2#@.release.}"
sed -n "s/.*\"$key\":\"\([^\"]*\)\".*/\1/p"
EOF
got="$(fw_info "$OUT/fw/missing")"
if [ "$got" = "24.10.8 ramips/mt7621 mipsel_24kc" ]; then
	ok "firmware version and target from ubus, arch from apk"
else
	bad "firmware version and target from ubus, arch from apk: $got"
fi
rm -f "$OUT/fw/bin/apk"
if [ "$(fw_info "$OUT/fw/missing")" = fail ] || command -v opkg >/dev/null 2>&1; then
	ok "no arch anywhere is an error"
else
	bad "no arch anywhere is an error"
fi

if command -v shellcheck >/dev/null 2>&1; then
	if out="$(shellcheck -s sh -f gcc -e SC1091,SC2034,SC3043,SC2086,SC2046,SC2317,SC2329 \
		"$FILES/usr/bin/mayhem" "$FILES/usr/libexec/mayhem/xray-run" "$FILES/usr/libexec/mayhem/scheduler" \
		"$FILES/etc/uci-defaults/90-mayhem" "$ROOT/tests/netns.sh" "$ROOT/tests/build-ucode.sh" "$ROOT/tests/health.sh" "$ROOT/tests/serverlist.sh" "$ROOT/tests/conns.sh" "$ROOT/tests/bbr.sh" \
		"$FILES/usr/share/mayhem/lib.sh" "$FILES/usr/share/mayhem/const.sh" "$ROOT/install.sh" 2>&1)"; then
		ok "shellcheck"
	else
		bad "shellcheck: $out"
	fi
fi

if command -v node >/dev/null 2>&1; then
	for f in "$ROOT"/luci-app-mayhem/htdocs/luci-static/resources/view/mayhem/*.js "$ROOT"/luci-app-mayhem/htdocs/luci-static/resources/mayhem/*.js "$ROOT"/luci-app-mayhem/htdocs/luci-static/resources/mayhem/page/*.js "$ROOT"/luci-app-mayhem/htdocs/luci-static/resources/mayhem/dash/*.js; do
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
			"$ROOT"/luci-app-mayhem/htdocs/luci-static/resources/mayhem/*.js "$ROOT"/luci-app-mayhem/htdocs/luci-static/resources/mayhem/page/*.js "$ROOT"/luci-app-mayhem/htdocs/luci-static/resources/mayhem/dash/*.js 2>&1)"; then
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

# Tunnel import into the server list and renaming the interface.
mkdir -p "$OUT/tun-uci" "$OUT/tun-proto"
cp "$ROOT/tests/luci/uci/network" "$ROOT/tests/luci/uci/firewall" "$ROOT/tests/uci/mayhem" "$OUT/tun-uci/"
: > "$OUT/tun-proto/amneziawg.sh"
if out="$(MAYHEM_UCI_DIR="$OUT/tun-uci" MAYHEM_RUN_DIR="$OUT/tun-run" MAYHEM_NETIFD_PROTO_DIR="$OUT/tun-proto" \
	uc "$ROOT/tests/tunnels.uc" "$ROOT/luci-app-mayhem/root/usr/share/rpcd/ucode/luci.mayhem" 2>&1)"; then
	ok "tunnel import into the server list, interface rename"
else
	bad "tunnels: $out"
fi

# Renaming servers: keys, subscription servers, tunnels.
mkdir -p "$OUT/ren-uci"
cp "$ROOT/tests/uci/mayhem" "$OUT/ren-uci/"
if out="$(MAYHEM_UCI_DIR="$OUT/ren-uci" MAYHEM_RUN_DIR="$OUT/ren-run" MAYHEM_SUBS_DIR="$OUT/ren-subs" \
	uc "$ROOT/tests/rename.uc" "$ROOT/luci-app-mayhem/root/usr/share/rpcd/ucode/luci.mayhem" 2>&1)"; then
	ok "renaming servers and subscriptions: keys, vmess, subscription servers, tunnels, chains"
else
	bad "renaming servers: $out"
fi

# Servers deleted from a subscription: left out, restored, old exclusions moved.
if out="$(UCODE="$UCODE" sh "$ROOT/tests/hidden.sh" 2>&1)"; then
	ok "deleted subscription servers: generator, delete and restore, migration"
else
	bad "deleted subscription servers: $out"
fi

# Freed memory of xray: a garbage collection is asked for when more than 8 MiB
# are freed but kept, not otherwise.
mkdir -p "$OUT/trim/bin" "$OUT/trim/run"
: > "$OUT/trim/run/active"
cat > "$OUT/trim/bin/curl" <<'EOF'
#!/bin/sh
for a; do url="$a"; done
echo "$url" >> "$TRIM/calls"
case "$url" in
	*/debug/vars) printf '{"memstats": {"HeapIdle": %s, "HeapReleased": 1048576}}' "$(cat "$TRIM/idle")" ;;
esac
EOF
chmod +x "$OUT/trim/bin/curl"
trim() {
	echo "$1" > "$OUT/trim/idle"
	: > "$OUT/trim/calls"
	TRIM="$OUT/trim" PATH="$OUT/trim/bin:$PATH" MAYHEM_LIB_DIR="$FILES/usr/share/mayhem" MAYHEM_RUN_DIR="$OUT/trim/run" sh -c '. "$1"; mayhem_mem_trim' _ "$FILES/usr/share/mayhem/lib.sh"
	grep -c 'gc=1' "$OUT/trim/calls"
}
if [ "$(trim 20971520)" = 1 ] && [ "$(trim 5242880)" = 0 ]; then
	ok "freed memory of xray: a collection with 19 MiB kept, none with 4"
else
	bad "freed memory of xray: $(cat "$OUT/trim/calls")"
fi

# Why xray restarted: the parts of the config that changed, servers live.uc
# could not change, how the previous xray ended; noted when the new one is up.
W="$OUT/why"
mkdir -p "$W"
why() { MAYHEM_RUN_DIR="$W" uc "$FILES/usr/share/mayhem/why.uc"; }
printf '%s\n' '{"dns":{"servers":["1.1.1.1"]},"log":{"loglevel":"warning"}}' > "$W/running.xray.key"
cp "$W/running.xray.key" "$W/xray.key"
w1="$(why)"
printf '%s\n' '{"dns":{"servers":["8.8.8.8"]},"log":{"loglevel":"warning"}}' > "$W/xray.key"
w2="$(why)"
echo "restart 1" >> "$W/xray.key"
w3="$(why)"
started() {
	MAYHEM_LIB_DIR="$FILES/usr/share/mayhem" MAYHEM_RUN_DIR="$W" sh -c '. "$1"; mayhem_xray_started' _ "$FILES/usr/share/mayhem/lib.sh"
	cut -d' ' -f2 "$W/xray.started"
}
echo "$(date +%s) config:dns" > "$W/restart.why"
w4="$(started)"
echo "$(date +%s) 2" > "$W/xray.exit"
w5="$(started)"
w6="$(started)"
if [ "$w1|$w2|$w3|$w4|$w5|$w6" = "|config:dns|servers|config:dns|exit:2|" ]; then
	ok "why xray restarted: config parts, servers, the end of the previous xray"
else
	bad "why xray restarted: got $w1|$w2|$w3|$w4|$w5|$w6"
fi

# One server list: subscriptions in it, their rules in its chain, fallback.uc.
if out="$(UCODE="$UCODE" sh "$ROOT/tests/serverlist.sh" 2>&1)"; then
	ok "server list: subscriptions, chains of subscriptions, migration"
else
	bad "server list: $(printf '%s' "$out" | grep -v '^ok')"
fi

# Active connections: the log folded into names, read into rows.
if out="$(UCODE="$UCODE" sh "$ROOT/tests/conns.sh" 2>&1)"; then
	ok "active connections"
else
	bad "active connections: $(printf '%s' "$out" | grep -v '^ok')"
fi

# TCP BBR at install and update: the module installed, the setting kept.
if out="$(sh "$ROOT/tests/bbr.sh" 2>&1)"; then
	ok "TCP BBR"
else
	bad "TCP BBR: $(printf '%s' "$out" | grep -v '^ok')"
fi

# Backup and restore of the config, with and without subscriptions and keys.
mkdir -p "$OUT/backup-uci" "$OUT/bin"
cp "$ROOT/tests/uci/mayhem" "$OUT/backup-uci/mayhem"
printf '#!/bin/sh\nexit 0\n' > "$OUT/bin/logger"
chmod +x "$OUT/bin/logger"
if out="$(PATH="$OUT/bin:$PATH" MAYHEM_UCI_DIR="$OUT/backup-uci" MAYHEM_RUN_DIR="$OUT/backup-run" \
	uc "$ROOT/tests/backup.uc" "$ROOT/luci-app-mayhem/root/usr/share/rpcd/ucode/luci.mayhem" 2>&1)"; then
	ok "backup with and without connections"
else
	bad "backup: $out"
fi

# Sections limited to devices: xray rules by source address (a MAC by its
# lease), kernel tunnels by MAC and address; a section whose devices have no
# address has no rules yet.
if ! uc -e "
	const x = json(require('fs').readfile('$OUT/devices/xray.json'));
	const r = filter(x.routing.rules, (q) => q.inboundTag?.[0] == 'tproxy-in');
	const mix = filter(r, (q) => q.domain && index(q.domain, 'domain:instagram.com') >= 0)[0];
	const awg = filter(r, (q) => q.domain && index(q.domain, 'domain:youtube.com') >= 0)[0];
	const vpn = filter(r, (q) => q.domain && index(q.domain, 'domain:chatgpt.com') >= 0);
	exit((join(',', mix?.source ?? []) == '192.168.1.20,10.0.0.0/24' && join(',', awg?.source ?? []) == '192.168.1.20,192.168.1.50/32' &&
		length(vpn) == 0) ? 0 : 1);
" 2>/dev/null; then
	bad "devices: xray rules are not limited to the devices"
elif ! grep -q 'ether saddr @tun_awg_sm ip daddr @tun_awg_4' "$OUT/devices/nft.conf" || ! grep -q 'ip saddr @tun_awg_s4 ip daddr @tun_awg_d4' "$OUT/devices/nft.conf" ||
	! grep -q 'elements = { aa:bb:cc:dd:ee:01 }' "$OUT/devices/nft.conf" || grep -q '^		ip daddr @tun_awg_4' "$OUT/devices/nft.conf"; then
	bad "devices: the kernel tunnel is not limited to the devices"
elif ! grep -q 'none of its devices has an address' "$OUT/devices/status.json" || ! grep -q 'no DHCP lease' "$OUT/devices/status.json"; then
	bad "devices: no warning for a device without an address"
else
	ok "devices: sections limited to some devices in xray and in the kernel"
fi

# DNS servers of a section: asked first for its names, through the section
# (tag), DoQ directly; a direct section's names go to xray then; proxy
# sections with FakeDNS do not use them; "all at once" is enableParallelQuery.
if ! uc -e "
	const x = json(require('fs').readfile('$OUT/secdns/xray.json'));
	const sv = x.dns.servers;
	const awg = filter(sv, (q) => q.tag == 'dns-sec-awg')[0];
	const bank = filter(sv, (q) => q.tag == 'dns-sec-bank');
	const r = filter(x.routing.rules, (q) => q.inboundTag?.[0] == 'dns-sec-awg' || q.inboundTag?.[0] == 'dns-sec-bank');
	exit((x.dns.enableParallelQuery === true && awg?.address == 'https://9.9.9.9/dns-query' && awg.queryStrategy == 'UseIPv4' &&
		index(sv, awg) < index(sv, filter(sv, (q) => q.address == 'https://1.1.1.1/dns-query')[0]) &&
		length(bank) == 2 && bank[0].address == 'quic+local://dns.adguard-dns.com' && bank[1].address == 'tcp://77.88.8.8' &&
		length(filter(sv, (q) => q.tag == 'dns-sec-mix')) == 0 && length(r) == 2 && r[0].balancerTag == 'bal-awg' && r[1].outboundTag == 'direct') ? 0 : 1);
" 2>/dev/null; then
	bad "section DNS: servers, order, tags or routing are wrong"
elif ! grep -q 'bank.test' "$OUT/secdns/dns.xray"; then
	bad "section DNS: dnsmasq does not send the direct section's names to xray"
elif ! grep -q 'own DNS is not used' "$OUT/secdns/status.json"; then
	bad "section DNS: no warning for a proxy section with FakeDNS"
elif ! uc -e "exit(json(require('fs').readfile('$OUT/tunnels/xray.json')).dns.enableParallelQuery == null ? 0 : 1);" 2>/dev/null; then
	bad "section DNS: servers are asked all at once without the option"
else
	ok "section DNS: own servers first and through the section, DoQ, all at once"
fi

# The domestic DNS is plain UDP: DoH and TCP entries are skipped with a
# warning (xray refuses a DoH server that has to resolve its own name), so
# the split of dnsmasq stays on and the plain servers are the upstream. A
# server in both the domestic and the remote list is warned about.
if ! uc -e "
	const x = json(require('fs').readfile('$OUT/doh-domestic/xray.json'));
	const addrs = map(x.dns.servers, (q) => q.address);
	exit((length(filter(addrs, (a) => match(a, /^(https|tcp):/) && !match(a, /1\.1\.1\.1|dns\.google/))) == 0 &&
		index(addrs, '1.1.1.1') >= 0 && index(addrs, '9.9.9.9') >= 0) ? 0 : 1);
" 2>/dev/null; then
	bad "domestic DNS: a DoH or TCP server is still among the xray DNS servers"
elif ! grep -q 'dns.comss.one/dns-query.* is skipped' "$OUT/doh-domestic/status.json" || ! grep -q 'tcp://77.88.8.8.* is skipped' "$OUT/doh-domestic/status.json"; then
	bad "domestic DNS: no warning for a skipped DoH or TCP server"
elif ! grep -q 'DNS server 1.1.1.1 is in both' "$OUT/doh-domestic/status.json"; then
	bad "domestic DNS: no warning for a server in both lists"
elif ! grep -q '^server=1.1.1.1$' "$OUT/doh-domestic/dns.xray" || ! grep -q '^server=9.9.9.9$' "$OUT/doh-domestic/dns.xray" || grep -q 'comss' "$OUT/doh-domestic/dns.xray"; then
	bad "domestic DNS: dnsmasq does not ask the plain servers"
else
	ok "domestic DNS: only plain UDP, DoH and TCP skipped with a warning"
fi

# Ports of a direct section: direct in the kernel and in xray, bad ones warned.
if ! grep -q 'meta l4proto { tcp, udp } th dport { 4501, 5000-5100 } counter return' "$OUT/secdns/nft.conf"; then
	bad "direct ports: not in the kernel"
elif ! uc -e "
	const r = filter(json(require('fs').readfile('$OUT/secdns/xray.json')).routing.rules, (q) => q.port == '4501,5000-5100');
	exit((length(r) == 1 && r[0].outboundTag == 'direct' && r[0].domain == null && r[0].ip == null) ? 0 : 1);
" 2>/dev/null; then
	bad "direct ports: no xray rule"
elif ! grep -q '70000' "$OUT/secdns/status.json" || ! grep -q '9-3' "$OUT/secdns/status.json"; then
	bad "direct ports: no warning for bad ports"
else
	ok "direct ports: any address on them goes direct, in the kernel and in xray"
fi

# Many servers: the check interval grows (two seconds per server at least).
python3 - "$ROOT/tests/models/subs.json" "$OUT/many.json" <<'PY'
import json, sys
m = json.load(open(sys.argv[1]))
m['settings']['probe_interval'] = '3m'
m['sections'] = [{'.name': 'auto', 'type': 'proxy', 'enabled': '1', 'select': 'auto', 'subscription': 'mysub', 'domain': ['youtube.com']}]
m['subscriptions']['mysub']['nodes'] = [{'name': 'S%d' % i, 'link': 'trojan://pw@s%d.example:443?sni=s.example#S%d' % (i, i)} for i in range(150)]
json.dump(m, open(sys.argv[2], 'w'))
PY
mkdir -p "$OUT/many"
if ! uc "$FILES/usr/share/mayhem/gen.uc" --model "$OUT/many.json" --out "$OUT/many" >/dev/null 2>&1; then
	bad "many servers: the generator failed"
elif ! uc -e "
	const a = json(require('fs').readfile('$OUT/many/xray.json')).burstObservatory?.pingConfig?.interval;
	const b = json(require('fs').readfile('$OUT/subs/xray.json')).burstObservatory?.pingConfig?.interval;
	exit((a == '5m' && b == '2m') ? 0 : 1);
" 2>/dev/null; then
	bad "many servers: the check interval does not grow"
else
	ok "many servers: 150 are checked every 5 minutes, a few as set"
fi

# The SHA-256 of an AmneziaWG package from the release description of GitHub.
mkdir -p "$OUT/awgd-bin"
printf '#!/bin/sh\nexec %s -L "%s/usr/share/ucode/*.uc" "$@"\n' "$UCODE" "$FILES" > "$OUT/awgd-bin/ucode"
chmod +x "$OUT/awgd-bin/ucode"
sed -n '/^awg_digest() {/,/^}/p' "$FILES/usr/bin/mayhem" > "$OUT/awgd.sh"
printf '{"assets":[{"name":"a.apk","digest":"sha256:%s"},{"name":"b.apk","digest":null}]}' "$(printf x | sha256sum | cut -c1-64)" > "$OUT/awgd.json"
got="$(PATH="$OUT/awgd-bin:$PATH" sh -c ". '$OUT/awgd.sh'; echo \"\$(awg_digest '$OUT/awgd.json' a.apk)/\$(awg_digest '$OUT/awgd.json' b.apk)/\$(awg_digest '$OUT/none' a.apk)\"")"
if [ "$got" = "$(printf x | sha256sum | cut -c1-64)//" ]; then
	ok "AmneziaWG package checksums from the GitHub release"
else
	bad "AmneziaWG checksums: $got"
fi

# Latency checks with a fake ping: ICMP of many servers at once (an
# obfuscated tunnel pings its real server, not the obfuscator on 127.0.0.1),
# TCP with the process's own sockets.
mkdir -p "$OUT/probe-uci" "$OUT/probe-bin"
cp "$ROOT/tests/luci/uci/network" "$OUT/probe-uci/"
cat >> "$OUT/probe-uci/network" <<'EOF'

config interface 'wg9'
	option proto 'wireguard'
	list addresses '10.8.9.2/32'

config wireguard_wg9
	option public_key 'Zm9vYmFyZm9vYmFyZm9vYmFyZm9vYmFyZm9vYmFyMTI='
	option endpoint_host '127.0.0.1'
	option endpoint_port '41820'
EOF
cat > "$OUT/probe-uci/mayhem" <<'EOF'
config obfs 'ob_wg9'
	option iface 'wg9'
	option kind 'phobos'
	option host '10.0.0.1'
	option port '4567'
	option lport '41820'
EOF
cat > "$OUT/probe-bin/ping" <<'EOF'
#!/bin/sh
echo "ping $*" >> "$FAKE_LOG"
for a; do addr="$a"; done
case " $* " in
*" -I awg0 "*) [ "$addr" = 1.1.1.1 ] && { echo "64 bytes from 1.1.1.1: seq=0 ttl=57 time=40.312 ms"; exit 0; } ;;
*) [ "$addr" = 10.0.0.1 ] && { echo "64 bytes from 10.0.0.1: seq=0 ttl=64 time=12.345 ms"; exit 0; } ;;
esac
sleep 2
exit 1
EOF
cat > "$OUT/probe-bin/curl" <<'EOF'
#!/bin/sh
echo "curl $*" >> "$FAKE_LOG"
f="$MAYHEM_RUN_DIR/curl.seq"
if [ -s "$f" ]; then
	head -n 1 "$f"
	sed -i 1d "$f"
	exit 0
fi
for a; do url="$a"; done
case "$url" in
*10.0.0.1:*) printf '0.001 0.021' ;;
*) sleep 1; printf '0.000000 0.000000' ;;
esac
EOF
chmod +x "$OUT/probe-bin/ping" "$OUT/probe-bin/curl"
if out="$(PATH="$OUT/probe-bin:$PATH" FAKE_LOG="$OUT/probe.log" MAYHEM_UCI_DIR="$OUT/probe-uci" MAYHEM_RUN_DIR="$OUT/probe-run" \
	uc "$ROOT/tests/probe.uc" "$ROOT/luci-app-mayhem/root/usr/share/rpcd/ucode/luci.mayhem" 2>&1)"; then
	ok "latency: ICMP and TCP of many servers at once, in waves"
else
	bad "latency: $out"
fi

# URL test over kept-alive connections against a fake SOCKS inbound.
if out="$(UCODE="$UCODE" sh "$ROOT/tests/warm.sh" 2>&1)"; then
	case "$out" in skip:*) printf 'skip %s\n' "URL test over kept-alive connections: ${out#skip: }" ;;
	*) ok "URL test over kept-alive connections" ;; esac
else
	bad "warm: $(printf '%s' "$out" | grep -v '^ok')"
fi

# WireGuard obfuscation set in the tunnel's dialog, and the service that runs
# the obfuscators.
mkdir -p "$OUT/obfs-uci" "$OUT/obfs-bin" "$OUT/obfs-run"
cp "$ROOT/tests/luci/uci/network" "$ROOT/tests/luci/uci/firewall" "$ROOT/tests/uci/mayhem" "$OUT/obfs-uci/"
printf '#!/bin/sh\nexit 0\n' > "$OUT/obfs-bin/wg-obfuscator"
cp "$OUT/obfs-bin/wg-obfuscator" "$OUT/obfs-bin/phantun_client"
chmod +x "$OUT/obfs-bin/wg-obfuscator" "$OUT/obfs-bin/phantun_client"
if out="$(MAYHEM_UCI_DIR="$OUT/obfs-uci" MAYHEM_RUN_DIR="$OUT/obfs-run" MAYHEM_WG_OBFUSCATOR="$OUT/obfs-bin/wg-obfuscator" \
	MAYHEM_PHANTUN="$OUT/obfs-bin/phantun_client" uc "$ROOT/tests/obfs.uc" "$ROOT/luci-app-mayhem/root/usr/share/rpcd/ucode/luci.mayhem" 2>&1)"; then
	ok "WireGuard obfuscation: Phobos and fake TCP, endpoint, MTU, firewall zone"
else
	bad "obfuscation: $out"
fi

if out="$(sh "$ROOT/tests/obfs-svc.sh" 2>&1)"; then
	ok "obfuscation service: wg-obfuscator with a config file, phantun with its TUN device"
else
	bad "obfuscation service: $out"
fi

# Servers or remote DNS that stop answering: direct and back, or the kill switch.
if out="$(UCODE="$UCODE" sh "$ROOT/tests/health.sh" 2>&1)"; then
	ok "health: sections and remote DNS go direct and come back, kill switch"
else
	bad "health: $(printf '%s' "$out" | grep -v '^ok')"
fi

# What dnsmasq asks while the remote DNS is down: names with fake addresses
# stay with xray, tunnel names go to the provider; nothing without remote DNS.
mkdir -p "$OUT/dnsfb"
sed -e 's/"keyword:tube",//' -e 's/"regexp:[^"]*"/"full:a1.test"/' -e 's/"settings": {/"settings": {\n    "killswitch": "1",/' "$ROOT/tests/models/tunnels.json" > "$OUT/dnsfb.json"
if ! uc "$FILES/usr/share/mayhem/gen.uc" --model "$OUT/dnsfb.json" --out "$OUT/dnsfb" 2>"$OUT/dnsfb.log"; then
	bad "dns fallback: generator failed: $(cat "$OUT/dnsfb.log")"
elif ! grep -q '^@ISP@$' "$OUT/dnsfb/dns.fallback" || ! grep -q 'instagram.com' "$OUT/dnsfb/dns.fallback" || \
     ! grep -q 'chatgpt.com' "$OUT/dnsfb/dns.fallback" || grep -q 'youtube.com\|down.test' "$OUT/dnsfb/dns.fallback" || \
     ! grep -q 'youtube.com' "$OUT/dnsfb/dns.xray"; then
	bad "dns fallback: $(tr '\n' '|' < "$OUT/dnsfb/dns.fallback") / $(tr '\n' '|' < "$OUT/dnsfb/dns.xray")"
elif ! grep -q '^MAYHEM_KILLSWITCH=1$' "$OUT/dnsfb/env" || ! grep -q '"killswitch": *true' "$OUT/dnsfb/nodes.json"; then
	bad "kill switch is not passed on (env, nodes.json)"
elif [ -s "$OUT/lists/dns.fallback" ]; then
	bad "dns fallback without a remote DNS in use: $(cat "$OUT/lists/dns.fallback")"
else
	ok "dns fallback: provider for tunnel names, fake names stay with xray; kill switch passed on"
fi

for f in "$ROOT"/luci-app-mayhem/root/usr/share/luci/menu.d/*.json "$ROOT"/luci-app-mayhem/root/usr/share/rpcd/acl.d/*.json; do
	uc -e "json(require('fs').readfile('$f'))" >/dev/null 2>&1 && ok "json $(basename "$f")" || bad "json $(basename "$f")"
done

rm -rf "$OUT"
[ "$fail" = 0 ] && echo "all tests passed" || echo "some tests failed"
exit "$fail"
