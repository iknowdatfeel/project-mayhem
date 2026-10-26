#!/bin/sh
# Active connections on the dashboard: the rpcd method switches xray's
# connection log between /dev/null and a file and reads it - devices by their
# DHCP names, domains from the DNS answers in the same log, outbound tags as
# sections and servers. UCODE points to the ucode to use.
#   UCODE=/opt/ucode-24.10/ucode tests/conns.sh

set -u

ROOT="$(cd "$(dirname "$0")/.." && pwd)"
FILES="$ROOT/mayhem/files"
UCODE="${UCODE:-ucode}"
T="$(mktemp -d)"
fail=0

ok() { printf 'ok   %s\n' "$1"; }
bad() { printf 'FAIL %s\n' "$1"; fail=1; }

mkdir -p "$T/run" "$T/bin"
# shellcheck disable=SC2016
printf '#!/bin/sh\necho "$*" >> "%s/xray.calls"\n' "$T" > "$T/bin/xray"
chmod +x "$T/bin/xray"
sleep 60 & live=$!
echo "$live" > "$T/run/xray.pid"

cat > "$T/run/nodes.json" <<'JSON'
{ "sections": { "pool": { "type": "proxy", "pool": true, "balancer": "bal-pool",
  "nodes": [ { "tag": "n-pool-aaaa", "name": "Amsterdam", "protocol": "vless" } ] },
  "games": { "type": "interface", "interface": "awg0", "device": "awg0", "tproto": "amneziawg" } } }
JSON

# The router: LAN 192.168.1.1, WAN 203.0.113.5, a tunnel 10.8.0.2.
printf '#!/bin/sh\nprintf "%%s\\n" "2: br-lan    inet 192.168.1.1/24 brd 192.168.1.255 scope global br-lan" "3: wan    inet 203.0.113.5/24 scope global wan" "9: awg0    inet 10.8.0.2/32 scope global awg0"\n' > "$T/bin/addrs"
chmod +x "$T/bin/addrs"

# Tracked connections: through xray (marked, no NAT), direct past xray
# (NAT to the WAN address), into the tunnel in the kernel (NAT to its
# address), xray's own to its server, DNS to the router.
cat > "$T/conntrack" <<'CT'
ipv4     2 tcp      6 7431 ESTABLISHED src=192.168.1.187 dst=142.250.74.110 sport=48398 dport=443 packets=10 bytes=1000 src=142.250.74.110 dst=192.168.1.187 sport=443 dport=48398 packets=10 bytes=5000 [ASSURED] mark=268435456 zone=0 use=2
ipv4     2 tcp      6 7431 ESTABLISHED src=192.168.1.187 dst=142.250.74.110 sport=48399 dport=443 packets=1 bytes=100 src=142.250.74.110 dst=192.168.1.187 sport=443 dport=48399 packets=1 bytes=100 [ASSURED] mark=268435456 zone=0 use=2
ipv4     2 tcp      6 7431 ESTABLISHED src=192.168.1.20 dst=77.88.55.88 sport=6000 dport=443 packets=5 bytes=900 src=77.88.55.88 dst=203.0.113.5 sport=443 dport=6000 packets=5 bytes=9000 [ASSURED] mark=0 zone=0 use=2
ipv4     2 udp      17 170 src=192.168.1.20 dst=34.1.2.3 sport=7000 dport=7777 packets=5 bytes=500 src=34.1.2.3 dst=10.8.0.2 sport=7777 dport=7000 packets=5 bytes=600 [ASSURED] mark=0 zone=0 use=2
ipv4     2 tcp      6 7431 ESTABLISHED src=203.0.113.5 dst=185.132.132.100 sport=40000 dport=443 packets=5 bytes=900 src=185.132.132.100 dst=203.0.113.5 sport=443 dport=40000 packets=5 bytes=900 [ASSURED] mark=0 zone=0 use=2
ipv4     2 udp      17 20 src=192.168.1.20 dst=192.168.1.1 sport=5353 dport=53 packets=1 bytes=60 src=192.168.1.1 dst=192.168.1.20 sport=53 dport=5353 packets=1 bytes=120 mark=0 zone=0 use=2
ipv4     2 tcp      6 100 TIME_WAIT src=192.168.1.20 dst=8.8.8.8 sport=6001 dport=443 packets=5 bytes=900 src=8.8.8.8 dst=203.0.113.5 sport=443 dport=6001 packets=5 bytes=900 mark=0 zone=0 use=2
CT

call() {
	MAYHEM_RUN_DIR="$T/run" MAYHEM_LIB_DIR="$FILES/usr/share/mayhem" MAYHEM_XRAY_BIN="$T/bin/xray" MAYHEM_LEASES="$T/leases" MAYHEM_CONNTRACK="$T/conntrack" MAYHEM_ADDRS_CMD="$T/bin/addrs" \
		"$UCODE" -L "$FILES/usr/share/ucode/*.uc" -e "
		const p = loadfile('$ROOT/luci-app-mayhem/root/usr/share/rpcd/ucode/luci.mayhem')()['luci.mayhem'];
		print(sprintf('%J', p.connections.call({ args: $1 })));
	"
}

# The window opens: the log becomes a file, xray reopens it.
ln -sfn /dev/null "$T/run/conn.log"
call '{}' > "$T/out1"
if [ -f "$T/run/conn.log" ] && [ ! -L "$T/run/conn.log" ] && grep -q restartlogger "$T/xray.calls" && [ -f "$T/run/conn.watch" ]; then
	ok "opening the connections turns the log on"
else
	bad "log on: $(ls -l "$T/run") / $(cat "$T/xray.calls" 2>/dev/null) / $(cat "$T/out1")"
fi

cat >> "$T/run/conn.log" <<'LOG'
2026/10/26 19:06:10.100000 DOH//1.1.1.1 got answer: www.youtube.com. -> [142.250.74.110, 142.250.74.111] 23ms
2026/10/26 19:06:11.123456 from 192.168.1.187:48398 accepted tcp:142.250.74.110:443 [tproxy-in >> n-pool-aaaa]
LOG
echo '1793030000 aa:bb:cc:dd:ee:ff 192.168.1.187 iPhone *' > "$T/leases"

out="$(call '{}')"
row() { printf '%s' "$out" | tr '}' '\n' | grep -- "$1"; }
if ! row '"host": "142.250.74.110"' | grep -q '"domain": "www.youtube.com"' || ! row '"host": "142.250.74.110"' | grep -q '"server": "Amsterdam"' ||
   ! printf '%s' "$out" | grep -q '"device": "iPhone"'; then
	bad "through xray, server and name from its log: $out"
elif ! row '"sport\|"host": "142.250.74.110"' | grep -q '"kind": "xray"'; then
	bad "through xray before the log was on: $out"
elif ! row '"host": "77.88.55.88"' | grep -q '"kind": "direct"'; then
	bad "direct past xray: $out"
elif ! row '"host": "34.1.2.3"' | grep -q '"kind": "tunnel"'; then
	bad "into a kernel tunnel: $out"
elif printf '%s' "$out" | grep -q '185.132.132.100\|"port": 53\|8.8.8.8'; then
	bad "the router's own, DNS to the router and closed connections are not listed: $out"
else
	ok "connections: through xray, direct past it, into a tunnel"
fi

# One device: only its connections, the list of devices stays whole.
out="$(call '{ "device": "192.168.1.20" }')"
if printf '%s' "$out" | grep -q '"ip": "192.168.1.187", "network"'; then
	bad "device filter: another device's connections are listed: $out"
elif ! printf '%s' "$out" | grep -q '"host": "77.88.55.88"' || ! printf '%s' "$out" | grep -q '"devices": \[.*192.168.1.187.*\]'; then
	bad "device filter: $out"
else
	ok "connections of one device, every device in the list"
fi

# The window closes: back to /dev/null.
call '{ "stop": true }' > /dev/null
if [ -L "$T/run/conn.log" ] && [ ! -f "$T/run/conn.watch" ]; then
	ok "closing the connections turns the log off"
else
	bad "log off: $(ls -l "$T/run")"
fi

# Nobody asked for a minute: the scheduler turns it off by itself.
call '{}' > /dev/null
echo $(( $(date +%s) - 120 )) > "$T/run/conn.watch"
MAYHEM_RUN_DIR="$T/run" MAYHEM_LIB_DIR="$FILES/usr/share/mayhem" MAYHEM_XRAY_BIN="$T/bin/xray" \
	sh -c '. "$MAYHEM_LIB_DIR/lib.sh"; mayhem_conn_log_idle'
if [ -L "$T/run/conn.log" ]; then
	ok "the log goes off when nobody looks"
else
	bad "idle log: $(ls -l "$T/run")"
fi

kill "$live" 2>/dev/null
rm -rf "$T"
[ "$fail" = 0 ] && echo "connection tests passed"
exit "$fail"
