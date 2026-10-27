#!/bin/sh
# Active connections on the dashboard: xray's connection log is always a file,
# the scheduler folds it into conn.names (mayhem_conn_fold, run here with
# busybox awk when there is one, as on the router), the rpcd method reads both
# - devices by their DHCP names (IPv6 by MAC), domains from the DNS answers,
# outbound tags as sections and servers. UCODE points to the ucode to use.
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

# The router: LAN 192.168.1.1, WAN 203.0.113.5, a tunnel 10.8.0.2. The
# iPhone also has fd00::a1b:2c3d:4e5f:1.
printf '#!/bin/sh\necho "fd00::a1b:2c3d:4e5f:1 dev br-lan lladdr AA:BB:CC:DD:EE:FF REACHABLE"\n' > "$T/bin/neigh"
chmod +x "$T/bin/neigh"
if command -v busybox >/dev/null 2>&1; then
	printf '#!/bin/sh\nexec busybox awk "$@"\n' > "$T/bin/awk"
	chmod +x "$T/bin/awk"
fi
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
ipv6     10 tcp      6 7431 ESTABLISHED src=0000:0000:0000:0000:0000:0000:0000:0001 dst=2a00:1450:4010:0c0e:0000:0000:0000:0065 sport=50000 dport=443 packets=5 bytes=900 src=2a00:1450:4010:0c0e:0000:0000:0000:0065 dst=0000:0000:0000:0000:0000:0000:0000:0001 sport=443 dport=50000 packets=5 bytes=900 [ASSURED] mark=0 zone=0 use=2
ipv6     10 tcp      6 7431 ESTABLISHED src=fd00:0000:0000:0000:0a1b:2c3d:4e5f:0001 dst=2a00:1450:4010:0c0e:0000:0000:0000:0065 sport=50001 dport=443 packets=5 bytes=700 src=2a00:1450:4010:0c0e:0000:0000:0000:0065 dst=fd00:0000:0000:0000:0a1b:2c3d:4e5f:0001 sport=443 dport=50001 packets=5 bytes=700 [ASSURED] mark=268435456 zone=0 use=2
ipv4     2 udp      17 20 src=192.168.1.20 dst=8.8.4.4 sport=5354 dport=53 packets=1 bytes=60 src=192.168.1.1 dst=192.168.1.20 sport=53 dport=5354 packets=1 bytes=120 mark=0 zone=0 use=2
ipv4     2 tcp      6 7431 ESTABLISHED src=198.51.100.7 dst=203.0.113.5 sport=40001 dport=51413 packets=5 bytes=400 src=192.168.1.187 dst=198.51.100.7 sport=51413 dport=40001 packets=5 bytes=600 [ASSURED] mark=0 zone=0 use=2
ipv6     10 udp      17 170 src=2001:0db8:0000:0000:0000:0000:0000:0099 dst=fd00:0000:0000:0000:0a1b:2c3d:4e5f:0001 sport=40002 dport=51413 packets=5 bytes=300 src=fd00:0000:0000:0000:0a1b:2c3d:4e5f:0001 dst=2001:0db8:0000:0000:0000:0000:0000:0099 sport=51413 dport=40002 packets=5 bytes=300 [ASSURED] mark=0 zone=0 use=2
ipv4     2 icmp     1 29 src=192.168.1.20 dst=1.1.1.1 type=8 code=0 id=7 packets=1 bytes=84 src=1.1.1.1 dst=192.168.1.20 type=0 code=0 id=7 packets=1 bytes=84 mark=0 zone=0 use=2
ipv4     2 tcp      6 100 TIME_WAIT src=192.168.1.20 dst=8.8.8.8 sport=6001 dport=443 packets=5 bytes=900 src=8.8.8.8 dst=203.0.113.5 sport=443 dport=6001 packets=5 bytes=900 mark=0 zone=0 use=2
CT

call() {
	MAYHEM_RUN_DIR="$T/run" MAYHEM_LIB_DIR="$FILES/usr/share/mayhem" MAYHEM_XRAY_BIN="$T/bin/xray" MAYHEM_LEASES="$T/leases" MAYHEM_CONNTRACK="$T/conntrack" MAYHEM_ADDRS_CMD="$T/bin/addrs" MAYHEM_NEIGH_CMD="$T/bin/neigh" PATH="$T/bin:$PATH" \
		"$UCODE" -L "$FILES/usr/share/ucode/*.uc" -e "
		const p = loadfile('$ROOT/luci-app-mayhem/root/usr/share/rpcd/ucode/luci.mayhem')()['luci.mayhem'];
		print(sprintf('%J', p.connections.call({ args: $1 })));
	"
}

fold() {
	MAYHEM_RUN_DIR="$T/run" MAYHEM_LIB_DIR="$FILES/usr/share/mayhem" PATH="$T/bin:$PATH" MAYHEM_CONN_NAMES="${1:-3000}" \
		sh -c '. "$MAYHEM_LIB_DIR/lib.sh"; mayhem_conn_fold'
}

# An xray started by an older xray-run writes to /dev/null: the window makes
# it a file and xray reopens it.
ln -sfn /dev/null "$T/run/conn.log"
call '{}' > "$T/out1"
if [ -f "$T/run/conn.log" ] && [ ! -L "$T/run/conn.log" ] && grep -q restartlogger "$T/xray.calls"; then
	ok "an old /dev/null log becomes a file"
else
	bad "log on: $(ls -l "$T/run") / $(cat "$T/xray.calls" 2>/dev/null) / $(cat "$T/out1")"
fi

# Before the window: the DNS answer and the connection are already folded
# (the scheduler), the log has only what came after.
cat >> "$T/run/conn.log" <<'LOG'
2026/10/26 19:06:10.100000 DOH//1.1.1.1 got answer: www.youtube.com. -> [142.250.74.110, 142.250.74.111, 198.18.0.5] 23ms
2026/10/26 19:06:10.200000 DOH//1.1.1.1 got answer: www.google.com. -> [2a00:1450:4010:c0e::65] 23ms
2026/10/26 19:06:11.123456 from 192.168.1.187:48398 accepted tcp:142.250.74.110:443 [tproxy-in >> n-pool-aaaa]
2026/10/26 19:06:11.223456 from [fd00::a1b:2c3d:4e5f:1]:50001 accepted tcp:[2a00:1450:4010:c0e::65]:443 [tproxy-in -> n-pool-aaaa] email: x
LOG
fold
if [ -s "$T/run/conn.log" ] || ! grep -qx 'd 142.250.74.110 www.youtube.com' "$T/run/conn.names" ||
   grep -q '198.18' "$T/run/conn.names" || ! grep -qx 'c tcp 192.168.1.187:48398 n-pool-aaaa' "$T/run/conn.names" ||
   ! grep -qx 'c tcp fd00::a1b:2c3d:4e5f:1:50001 n-pool-aaaa' "$T/run/conn.names"; then
	bad "fold: log $(wc -c < "$T/run/conn.log"), names: $(cat "$T/run/conn.names")"
else
	ok "the log folds into names and empties"
fi

# A second fold keeps the last answer for an address, and only the last N.
cat >> "$T/run/conn.log" <<'LOG'
2026/10/26 19:07:10.100000 [::1]:53 cache HIT: m.youtube.com. -> [142.250.74.111] 0s
2026/10/26 19:07:10.100000 DOH//1.1.1.1 got answer: a.example. -> [203.0.113.10] 1ms
2026/10/26 19:07:10.100000 DOH//1.1.1.1 got answer: b.example. -> [203.0.113.11] 1ms
LOG
cp "$T/run/conn.names" "$T/names.keep"
fold 3
if ! grep -qx 'd 142.250.74.111 m.youtube.com' "$T/run/conn.names" || [ "$(grep -c '^d ' "$T/run/conn.names")" != 3 ] ||
   grep -q '142.250.74.110' "$T/run/conn.names" || [ "$(grep -c '^c ' "$T/run/conn.names")" != 2 ]; then
	bad "fold cap: $(cat "$T/run/conn.names")"
else
	ok "the names keep the last answer and the last N of each kind"
fi
cp "$T/names.keep" "$T/run/conn.names"
: > "$T/run/conn.log"

echo '1793030000 aa:bb:cc:dd:ee:ff 192.168.1.187 iPhone *' > "$T/leases"

out="$(call '{}')"
row() { printf '%s' "$out" | tr '}' '\n' | grep -- "$1"; }
if ! row '"host": "142.250.74.110"' | grep -q '"domain": "www.youtube.com"' || ! row '"host": "142.250.74.110"' | grep -q '"server": "Amsterdam"' ||
   ! printf '%s' "$out" | grep -q '"device": "iPhone"'; then
	bad "through xray, server and name opened before the window: $out"
elif printf '%s' "$out" | grep -q '"kind": "xray"' || ! printf '%s' "$out" | grep -q '"host": "142.250.74.110", [^]]*"server": "Amsterdam"[^}]*}, "count": 2, "bytes": 6200'; then
	bad "through xray, not in the log: one row with the known server, traffic summed: $out"
elif ! row '"host": "77.88.55.88"' | grep -q '"kind": "direct"'; then
	bad "direct past xray: $out"
elif ! row '"host": "34.1.2.3"' | grep -q '"kind": "tunnel"'; then
	bad "into a kernel tunnel: $out"
elif printf '%s' "$out" | grep -q '185.132.132.100\|"port": 53, "fake": false, "domain": null, "route": {"kind": "direct"\|8.8.8.8\|0000:\|"ip": "::1"'; then
	bad "the router's own (IPv4 and ::1), DNS to the router and closed connections are not listed: $out"
elif ! row '"host": "8.8.4.4"' | grep -q '"kind": "dns"'; then
	bad "DNS to another server taken by the router: $out"
elif ! row '"ip": "fd00::a1b:2c3d:4e5f:1"' | grep -q '"device": "iPhone"' ||
     ! row '"ip": "fd00::a1b:2c3d:4e5f:1"' | grep -q '"domain": "www.google.com"' ||
     ! row '"ip": "fd00::a1b:2c3d:4e5f:1"' | grep -q '"server": "Amsterdam"'; then
	bad "IPv6: short address, device by MAC, name and server: $out"
elif ! printf '%s' "$out" | grep -q '"counts": { "tcp": 5, "udp": 3 }'; then
	bad "TCP and UDP counts: $out"
elif ! printf '%s' "$out" | grep -q '"hidden": { "total": 4, "router": 2, "to_router": 1, "closing": 1, "local": 0, "other": 0 }' ||
     [ $(( 5 + 3 + 4 )) != "$(grep -cE ' (tcp|udp) ' "$T/conntrack")" ]; then
	bad "hidden: the rows and the hidden add up to the kernel's TCP and UDP: $(grep -cE ' (tcp|udp) ' "$T/conntrack") / $out"
elif ! printf '%s' "$out" | grep -q '"device": "iPhone", "ip": "192.168.1.187", "network": "tcp", "host": "198.51.100.7", "port": null, [^}]*"route": { "kind": "inbound", "port": 51413 }' ||
     ! printf '%s' "$out" | grep -q '"ip": "fd00::a1b:2c3d:4e5f:1", "network": "udp", "host": "2001:db8::99", "port": null, [^}]*"route": { "kind": "inbound", "port": 51413 }' ||
     printf '%s' "$out" | grep -q '"ip": "198.51.100.7"\|"ip": "2001:db8::99"'; then
	bad "inbound through a forwarded port and to an IPv6 device: $out"
else
	ok "connections: through xray, direct, tunnel, DNS, IPv6, inbound, counts, hidden"
fi

# One device: only its connections, the list of devices stays whole.
out="$(call '{ "device": "192.168.1.20" }')"
if printf '%s' "$out" | grep -q '"ip": "192.168.1.187", "network"'; then
	bad "device filter: another device's connections are listed: $out"
elif ! printf '%s' "$out" | grep -q '"host": "77.88.55.88"' || ! printf '%s' "$out" | grep -q '"devices": \[.*192.168.1.187.*\]' ||
     ! printf '%s' "$out" | grep -q '"counts": { "tcp": 1, "udp": 2 }'; then
	bad "device filter: $out"
else
	ok "connections of one device, every device in the list"
fi

# An address of the FakeDNS range is Mayhem's fake one only while xray has
# FakeDNS: otherwise it came from elsewhere (a VPN app on the device).
echo 'ipv4     2 udp      17 170 src=192.168.1.187 dst=198.18.95.170 sport=19001 dport=19000 packets=2 bytes=262 src=198.18.95.170 dst=192.168.1.187 sport=19000 dport=19001 packets=0 bytes=0 mark=268435456 zone=0 use=2' >> "$T/conntrack"
with_fake="$(call '{}')"
sed -i 's/^{ "sections"/{ "fakedns": false, "sections"/' "$T/run/nodes.json"
without_fake="$(call '{}')"
if ! printf '%s' "$with_fake" | grep -q '"host": "198.18.95.170", "port": 19000, "fake": true' ||
   ! printf '%s' "$without_fake" | grep -q '"host": "198.18.95.170", "port": 19000, "fake": false'; then
	bad "FakeDNS addresses: $with_fake / $without_fake"
else
	ok "the FakeDNS range is marked only while xray has FakeDNS"
fi

# The window closes: the log stays a file (it is folded by the scheduler).
call '{ "stop": true }' > /dev/null
if [ -f "$T/run/conn.log" ] && [ ! -L "$T/run/conn.log" ]; then
	ok "closing the window keeps the log"
else
	bad "log after closing: $(ls -l "$T/run")"
fi

kill "$live" 2>/dev/null
rm -rf "$T"
[ "$fail" = 0 ] && echo "connection tests passed"
exit "$fail"
