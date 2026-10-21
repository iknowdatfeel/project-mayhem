#!/bin/sh
# health.uc with stand-ins for curl, xray and logger: sections go direct when
# none of their servers answers and come back when one does, a fallback chain
# only when all of its servers are down, the remote DNS goes to the provider
# and back, and with the kill switch on nothing goes direct.
#   UCODE=ucode tests/health.sh

set -u

ROOT="$(cd "$(dirname "$0")/.." && pwd)"
FILES="$ROOT/mayhem/files"
UCODE="${UCODE:-ucode}"
T="$(mktemp -d)"
fail=0

ok() { printf 'ok   %s\n' "$1"; }
bad() {
	printf 'FAIL %s\n' "$1"
	fail=1
	if [ -n "${GITHUB_ACTIONS:-}" ]; then
		printf '::error title=%s::%s\n' "$(basename "$0")" "$1"
	fi
}

mkdir -p "$T/bin" "$T/run" "$T/dnsmasq"
export MAYHEM_RUN_DIR="$T/run" MAYHEM_LIB_DIR="$FILES/usr/share/mayhem" MAYHEM_XRAY_BIN="$T/bin/xray" \
	MAYHEM_DNS_SERVERS="$T/dnsmasq/mayhem.servers" MAYHEM_RESOLV_AUTO="$T/resolv.conf.auto" STUB="$T"

echo 'nameserver 10.9.9.9' > "$T/resolv.conf.auto"

# curl: servers listed in $STUB/dead do not answer, the DoH check fails while
# $STUB/dns_dead exists; the metrics give $STUB/obs.json.
cat > "$T/bin/curl" <<'EOF'
#!/bin/sh
user="" url=""
while [ $# -gt 0 ]; do
	case "$1" in
		-x) user="${2#socks5h://}"; user="${user%%:*}"; shift ;;
		-o|-m|-w|-H) shift ;;
		-*) ;;
		*) url="$1" ;;
	esac
	shift
done
echo "curl $user $url" >> "$STUB/curl.log"
case "$url" in
	*/debug/vars) printf '{"observatory":%s}' "$(cat "$STUB/obs.json" 2>/dev/null || echo '{}')"; exit 0 ;;
	*dns=*) if [ -f "$STUB/dns_dead" ]; then printf 000; else printf 200; fi; exit 0 ;;
esac
if grep -qx "$user" "$STUB/dead" 2>/dev/null; then printf 000; else printf 204; fi
EOF
# shellcheck disable=SC2016
printf '#!/bin/sh\necho "$*" >> "$STUB/xray.log"\n' > "$T/bin/xray"
# shellcheck disable=SC2016
printf '#!/bin/sh\nshift 4; echo "$*" >> "$STUB/syslog"\n' > "$T/bin/logger"
printf '#!/bin/sh\nexit 1\n' > "$T/bin/pidof"
chmod +x "$T/bin/"*
export PATH="$T/bin:$PATH"

: > "$T/run/active"
echo 4242 > "$T/run/xray.pid"

# A server list with one server, an automatic section of three and a chain.
nodes() {
	cat > "$T/run/nodes.json" <<EOF
{ "generated": 1, "killswitch": $1, "probe_url": "http://www.gstatic.com/generate_204",
  "default_section": "pool",
  "dns_check": { "servers": [ { "address": "https://1.1.1.1/dns-query", "host": "1.1.1.1" } ], "via": "sec-pool" },
  "sections": {
    "pool": { "type": "proxy", "mode": "single", "nodes": [ { "tag": "n-pool-a", "name": "A" } ] },
    "auto": { "type": "proxy", "mode": "auto", "balancer": "bal-auto",
      "nodes": [ { "tag": "n-auto-1", "name": "1" }, { "tag": "n-auto-2", "name": "2" }, { "tag": "n-auto-3", "name": "3" } ] },
    "ch": { "type": "proxy", "mode": "fallback", "balancer": "bal-ch", "selected": "n-ch-1", "chain": [ "n-ch-1", "n-ch-2", "n-ch-3" ],
      "nodes": [ { "tag": "n-ch-1", "name": "c1" }, { "tag": "n-ch-2", "name": "c2" }, { "tag": "n-ch-3", "name": "c3" } ] },
    "tun": { "type": "interface", "balancer": "bal-tun", "nodes": [ { "tag": "i-tun-0", "name": "awg0" } ] }
  } }
EOF
}

printf '@ISP@\nserver=/youtube.com/127.0.0.1#12753\n' > "$T/run/dns.xray"
printf '@ISP@\n' > "$T/run/dns.fallback"

tick() { : > "$T/xray.log"; "$UCODE" -L "$FILES/usr/share/ucode/*.uc" "$FILES/usr/share/mayhem/health.uc" 2>"$T/err" || bad "health.uc: $(cat "$T/err")"; }
bo() { grep -c -- "-b $1 $2" "$T/xray.log"; }
down() { "$UCODE" -e "exit(json(require('fs').readfile('$T/run/health.json')).sections?.['$1']?.down ? 0 : 1)"; }

nodes false
echo '{ "n-auto-2": { "alive": true, "delay": 100 }, "n-ch-2": { "alive": true, "delay": 50 } }' > "$T/obs.json"

# Everything answers: nothing changes.
tick
if [ -s "$T/xray.log" ]; then bad "all answer: xray was told $(cat "$T/xray.log")"; else ok "all servers answer: nothing goes direct"; fi

# Every server goes silent; xray still believes in n-auto-2 and n-ch-2.
printf 'n-pool-a\nn-ch-1\nn-ch-2\nn-ch-3\nn-auto-1\nn-auto-2\nn-auto-3\n' > "$T/dead"
tick
if [ -s "$T/xray.log" ]; then bad "one failed check is enough to go direct"; else ok "one failed check: not direct yet"; fi
tick
if [ "$(bo bal-pool direct)" = 1 ] && [ "$(bo bal-ch direct)" = 1 ] && down pool && down ch; then
	ok "server list and fallback chain go direct after two failed checks"
else
	bad "direct after two checks: $(cat "$T/xray.log")"
fi

# automatic choice: n-auto-2, seen alive by xray, is tried as well and fails.
if down auto && [ "$(bo bal-auto direct)" = 1 ]; then ok "automatic section with no working server seen goes direct"; else bad "auto: $(cat "$T/xray.log")"; fi

# The chain: one of its servers answers again -> back to that one.
printf 'n-pool-a\nn-ch-1\nn-ch-2\nn-auto-1\nn-auto-2\nn-auto-3\n' > "$T/dead"
tick; tick
if [ "$(bo bal-ch n-ch-3)" = 1 ] && ! down ch && grep -q '"ch": *"n-ch-3"' "$T/run/fallback.json"; then
	ok "chain back on its working server"
else
	bad "chain back: $(cat "$T/xray.log") $(cat "$T/run/fallback.json" 2>/dev/null)"
fi

# The single server answers again: the balancer is let go.
printf 'n-ch-1\nn-ch-2\nn-auto-1\nn-auto-2\nn-auto-3\n' > "$T/dead"
tick
if grep -q -- '-b bal-pool -r' "$T/xray.log" && ! down pool; then ok "server list back when its server answers"; else bad "pool back: $(cat "$T/xray.log")"; fi

# A choice made meanwhile (reload: new "generated") while still down: direct again.
nodes false
sed -i 's/"generated": 1/"generated": 2/' "$T/run/nodes.json"
printf 'n-auto-1\nn-auto-2\nn-auto-3\n' > "$T/dead"
echo '{}' > "$T/obs.json"
tick
if [ "$(bo bal-auto direct)" = 1 ]; then ok "still down after a reload: direct again"; else bad "re-direct after reload: $(cat "$T/xray.log")"; fi

# An automatic section comes back on a server xray has not seen working:
# that server is pinned until xray's checks see one.
printf 'n-auto-1\nn-auto-2\n' > "$T/dead"
# servers are tried two per run: within two runs
for i in 1 2; do tick; [ "$(bo bal-auto n-auto-3)" = 1 ] && break; done
if [ "$(bo bal-auto n-auto-3)" = 1 ] && ! down auto; then ok "automatic section back, the answering server pinned"; else bad "auto pin: $(cat "$T/xray.log")"; fi
echo '{ "n-auto-3": { "alive": true, "delay": 80 } }' > "$T/obs.json"
tick
if grep -q -- '-b bal-auto -r' "$T/xray.log"; then ok "the pin goes once xray sees a working server"; else bad "auto unpin: $(cat "$T/xray.log")"; fi
printf 'n-auto-1\nn-auto-2\nn-auto-3\n' > "$T/dead"
echo '{}' > "$T/obs.json"
tick; tick

# Remote DNS: two failed checks -> the provider's DNS; back when it answers.
: > "$T/dns_dead"
tick; tick
if [ -f "$T/run/dns.degraded" ] && ! grep -q 12753 "$T/dnsmasq/mayhem.servers" && grep -q 'server=10.9.9.9' "$T/dnsmasq/mayhem.servers"; then
	ok "remote DNS down: dnsmasq asks the provider"
else
	bad "dns down: $(cat "$T/dnsmasq/mayhem.servers" 2>/dev/null)"
fi
rm -f "$T/dns_dead"
tick
if [ ! -f "$T/run/dns.degraded" ] && grep -q 'server=/youtube.com/127.0.0.1#12753' "$T/dnsmasq/mayhem.servers"; then
	ok "remote DNS back: dnsmasq asks xray again"
else
	bad "dns back: $(cat "$T/dnsmasq/mayhem.servers" 2>/dev/null)"
fi

# Kill switch on: the section that went direct is put back, nothing is
# checked, nothing goes direct.
: > "$T/dns_dead"
tick; tick
nodes true
: > "$T/curl.log"
tick
if down auto || grep -q direct "$T/xray.log" || [ -f "$T/run/dns.degraded" ]; then
	bad "kill switch: still direct: $(cat "$T/xray.log")"
elif grep -q -- '-b bal-auto -r' "$T/xray.log" && ! grep -q socks "$T/curl.log" && ! grep -q 'n-' "$T/curl.log"; then
	ok "kill switch: back from direct, no checks, nothing direct"
else
	bad "kill switch: $(cat "$T/xray.log") / $(cat "$T/curl.log")"
fi
tick; tick
if grep -q direct "$T/xray.log" || [ -f "$T/run/dns.degraded" ]; then bad "kill switch: went direct"; else ok "kill switch: dead servers stay as they are"; fi

# Tunnels: with the kill switch the route stays and the balancer keeps the tunnel.
rm -rf "$T/net"; mkdir -p "$T/net"
# shellcheck disable=SC2016
printf '#!/bin/sh\necho "ip $*" >> "$STUB/ip.log"\n' > "$T/bin/ip"
printf '#!/bin/sh\nexit 1\n' > "$T/bin/ping"
chmod +x "$T/bin/ip" "$T/bin/ping"
echo 'awg awg9 0x4000001 111 0' > "$T/run/tunnels"
for ks in 0 1; do
	echo "MAYHEM_KILLSWITCH=$ks" > "$T/run/env"
	: > "$T/ip.log"; : > "$T/xray.log"; rm -f "$T/run/tunnel.awg"
	sh -c '. "$MAYHEM_LIB_DIR/lib.sh"; mayhem_tunnels_check' 2>/dev/null
	st="$(cat "$T/run/tunnel.awg" 2>/dev/null)"
	if [ "$ks" = 0 ]; then
		if [ "$st" = down ] && grep -q 'route flush table 111' "$T/ip.log" && grep -q -- '-b bal-awg direct' "$T/xray.log"; then
			ok "tunnel down, no kill switch: its traffic goes direct"
		else
			bad "tunnel down: $st / $(cat "$T/ip.log") / $(cat "$T/xray.log")"
		fi
	elif [ "$st" = held ] && grep -q 'route replace' "$T/ip.log" && ! grep -q 'flush' "$T/ip.log" && ! grep -q direct "$T/xray.log"; then
		ok "tunnel down, kill switch: the route stays, nothing goes direct"
	else
		bad "tunnel held: $st / $(cat "$T/ip.log") / $(cat "$T/xray.log")"
	fi
done

rm -rf "$T"
[ "$fail" = 0 ] && echo "health tests passed"
exit "$fail"
