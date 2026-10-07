#!/bin/sh
# End-to-end test in network namespaces (needs root, iproute2, nftables with
# TPROXY, curl, python3, ucode and xray):
#
#   client (192.168.1.2) --- router: Mayhem + xray --- wan: web, 2 DNS, proxy server
#
#   sudo UCODE=ucode XRAY=/path/to/xray tests/netns.sh
#
# The web server answers with the source address it sees, which tells the path:
#   192.168.1.2  not intercepted (kernel direct)
#   45.0.0.1     xray direct (router WAN address)
#   45.0.0.2     through the proxy server in the wan namespace

set -u

ROOT="$(cd "$(dirname "$0")/.." && pwd)"
FILES="$ROOT/mayhem/files"
UCODE="${UCODE:-ucode}"
XRAY="${XRAY:-xray}"
WORK="$(mktemp -d)"
fail=0

export MAYHEM_LIB_DIR="$FILES/usr/share/mayhem"
export MAYHEM_RUN_DIR="$WORK/run"
export MAYHEM_DNSMASQ_INIT=true
export MAYHEM_XRAY_BIN="$XRAY"

SS_KEY='AAECAwQFBgcICQoLDA0ODw=='
SS_LINK='ss://2022-blake3-aes-128-gcm:AAECAwQFBgcICQoLDA0ODw%3D%3D@45.0.0.3:8443#srv'

ok() { printf 'ok   %s\n' "$1"; }
bad() { printf 'FAIL %s\n' "$1"; fail=1; }

expect() {
	# $1 description, $2 expected answer, rest: curl arguments
	local what="$1" want="$2" got
	shift 2
	got="$(ip netns exec client curl -s -m 4 "$@" 2>/dev/null)" || got="failed"
	[ "$got" = "$want" ] && ok "$what" || bad "$what: expected $want, got $got"
}

dns() {
	# $1 namespace, $2 server, $3 port, $4 name -> prints the A answer
	ip netns exec "$1" python3 - "$2" "$3" "$4" <<'PY'
import socket, struct, sys
server, port, name = sys.argv[1], int(sys.argv[2]), sys.argv[3]
s = socket.socket(socket.AF_INET, socket.SOCK_DGRAM); s.settimeout(5)
q = struct.pack('>HHHHHH', 7, 0x100, 1, 0, 0, 0) + b''.join(bytes([len(p)]) + p.encode() for p in name.split('.')) + b'\x00' + struct.pack('>HH', 1, 1)
s.sendto(q, (server, port))
try:
    d = s.recv(512)
    print(socket.inet_ntoa(d[-4:]) if struct.unpack('>H', d[6:8])[0] else 'none')
except Exception:
    print('timeout')
PY
}

expect_dns() {
	local got
	got="$(dns "$2" "$3" "$4" "$5")"
	[ "$got" = "$6" ] && ok "$1" || bad "$1: expected $6, got $got"
}

cleanup() {
	local n p
	for n in client router wan; do
		for p in $(ip netns pids "$n" 2>/dev/null); do kill "$p" 2>/dev/null; done
		ip netns del "$n" 2>/dev/null
	done
	rm -f /tmp/dnsmasq.d/mayhem.conf
	rm -rf "$WORK"
}

trap cleanup EXIT

start_mayhem() {
	# $1 model file
	mkdir -p "$MAYHEM_RUN_DIR"
	"$UCODE" -L "$FILES/usr/share/ucode/*.uc" ${UCODE_LIB:+-L "$UCODE_LIB"} \
		"$FILES/usr/share/mayhem/gen.uc" --model "$1" --out "$MAYHEM_RUN_DIR" 2>/dev/null || { bad "generator"; return 1; }
	ip netns exec router "$FILES/usr/libexec/mayhem/xray-run" > "$WORK/run.log" 2>&1 &

	local i=0
	while [ "$i" -lt 20 ]; do
		ip netns exec router nft list table inet mayhem >/dev/null 2>&1 && return 0
		sleep 1
		i=$((i + 1))
	done

	bad "Mayhem did not start"
	tail -n 20 "$WORK/run.log"
	return 1
}

stop_mayhem() {
	local p
	for p in $(ip netns pids router); do
		[ "$(cat "/proc/$p/comm" 2>/dev/null)" = xray-run ] && kill -TERM "$p"
	done
	sleep 2
}

proc_in() {
	# pid of process named $2 in namespace $1
	local p
	for p in $(ip netns pids "$1"); do
		[ "$(cat "/proc/$p/comm" 2>/dev/null)" = "$2" ] && { echo "$p"; return; }
	done
}

# --- network ------------------------------------------------------------------

cleanup 2>/dev/null
WORK="$(mktemp -d)"
mkdir -p "$MAYHEM_RUN_DIR"

for n in client router wan; do
	ip netns add "$n" && ip -n "$n" link set lo up || { echo "cannot create namespaces"; exit 1; }
done

ip link add c0 netns client type veth peer name br-lan netns router
ip link add wan0 netns router type veth peer name w0 netns wan
ip -n client addr add 192.168.1.2/24 dev c0
ip -n client link set c0 up
ip -n client route add default via 192.168.1.1
ip -n router addr add 192.168.1.1/24 dev br-lan
ip -n router link set br-lan up
ip -n router addr add 45.0.0.1/24 dev wan0
ip -n router link set wan0 up
ip -n router route add default via 45.0.0.2
for a in 2 3 4 6 7; do ip -n wan addr add "45.0.0.$a/24" dev w0; done
ip -n wan link set w0 up
ip -n wan route add 192.168.1.0/24 via 45.0.0.1
ip netns exec router sysctl -qw net.ipv4.ip_forward=1

cat > "$WORK/web.py" <<'PY'
import http.server, sys
class H(http.server.BaseHTTPRequestHandler):
    def do_GET(self):
        b = self.client_address[0].encode()
        self.send_response(200); self.send_header('Content-Length', str(len(b))); self.end_headers(); self.wfile.write(b)
    def log_message(self, *a): pass
http.server.ThreadingHTTPServer(('0.0.0.0', 8080), H).serve_forever()
PY

cat > "$WORK/dns.py" <<'PY'
import socket, struct, sys
bind_ip, answer = sys.argv[1], sys.argv[2]
s = socket.socket(socket.AF_INET, socket.SOCK_DGRAM); s.bind((bind_ip, 53))
while True:
    data, addr = s.recvfrom(512)
    qid = struct.unpack('>H', data[:2])[0]
    i = 12
    while data[i]: i += data[i] + 1
    qtype = struct.unpack('>H', data[i+1:i+3])[0]
    ans = b'\xc0\x0c' + struct.pack('>HHIH', 1, 1, 60, 4) + socket.inet_aton(answer) if qtype == 1 else b''
    s.sendto(struct.pack('>HHHHHH', qid, 0x8180, 1, 1 if ans else 0, 0, 0) + data[12:i+5] + ans, addr)
PY

cat > "$WORK/server.json" <<EOF
{ "log": { "loglevel": "warning" },
  "inbounds": [ { "listen": "45.0.0.3", "port": 8443, "protocol": "shadowsocks",
    "settings": { "method": "2022-blake3-aes-128-gcm", "password": "$SS_KEY", "network": "tcp,udp" } } ],
  "outbounds": [ { "protocol": "freedom" } ] }
EOF

ip netns exec wan python3 "$WORK/web.py" >/dev/null 2>&1 &
ip netns exec wan python3 "$WORK/dns.py" 45.0.0.2 45.0.0.2 >/dev/null 2>&1 &
ip netns exec wan python3 "$WORK/dns.py" 45.0.0.4 45.0.0.7 >/dev/null 2>&1 &
ip netns exec wan "$XRAY" run -c "$WORK/server.json" > "$WORK/server.log" 2>&1 &
sleep 2

# --- "only matched lists" mode -------------------------------------------------------

cat > "$WORK/lists.json" <<EOF
{
  "settings": { "mode": "lists", "interface": [ "br-lan" ], "ip_family": "ipv4_only", "log_level": "warning" },
  "dns": { "domestic": [ "45.0.0.2" ], "remote": [ "45.0.0.4" ], "via_proxy": "1", "proxy_section": "main", "hijack": "1" },
  "sections": [
    { ".name": "ads", "type": "block", "enabled": "1", "domain": [ "ads.test" ] },
    { ".name": "main", "type": "proxy", "enabled": "1", "link": "$SS_LINK",
      "domain": [ "youtube.test", "keyword:tube2" ], "ip": [ "45.0.0.7" ] },
    { ".name": "ru", "type": "exclusion", "enabled": "1", "ip": [ "45.0.0.6" ] }
  ],
  "runtime": { "wan_dns": [ "45.0.0.2" ], "ipv6": false, "mem_total_kb": 262144 }
}
EOF

echo "== lists mode"
if start_mayhem "$WORK/lists.json"; then
	expect "no rule -> xray direct" 45.0.0.1 http://45.0.0.2:8080/
	expect "domain -> proxy" 45.0.0.2 -H 'Host: youtube.test' http://45.0.0.2:8080/
	expect "subdomain -> proxy" 45.0.0.2 -H 'Host: www.youtube.test' http://45.0.0.2:8080/
	expect "keyword -> proxy" 45.0.0.2 -H 'Host: mytube2.example' http://45.0.0.2:8080/
	expect "block section" failed -H 'Host: ads.test' http://45.0.0.2:8080/
	expect "IP rule -> proxy" 45.0.0.2 http://45.0.0.7:8080/
	expect "exclusion IP -> kernel direct" 192.168.1.2 http://45.0.0.6:8080/
	expect_dns "proxy domain -> remote DNS" router 127.0.0.1 12753 youtube.test 45.0.0.7
	expect_dns "other domain -> domestic DNS" router 127.0.0.1 12753 other.test 45.0.0.2
	expect_dns "DNS to 1.2.3.4:53 is intercepted" client 1.2.3.4 53 youtube.test 45.0.0.7
	expect_dns "DNS to 8.8.8.8:53 is intercepted" client 8.8.8.8 53 vk.test 45.0.0.2

	kill -9 "$(proc_in router xray)" 2>/dev/null
	sleep 2
	ip netns exec router nft list table inet mayhem >/dev/null 2>&1 &&
		bad "rules removed after xray crash" || ok "rules removed after xray crash"
	expect "traffic goes direct while xray is down" 192.168.1.2 http://45.0.0.2:8080/
fi
stop_mayhem

# --- "everything through proxy" mode ---------------------------------------------

cat > "$WORK/global.json" <<EOF
{
  "settings": { "mode": "global", "default_section": "main", "interface": [ "br-lan" ], "ip_family": "prefer_ipv4" },
  "dns": { "domestic": [ "45.0.0.2" ], "remote": [ "45.0.0.4" ], "hijack": "1" },
  "sections": [
    { ".name": "main", "type": "proxy", "enabled": "1", "link": "$SS_LINK" },
    { ".name": "ru", "type": "exclusion", "enabled": "1", "domain": [ "gosuslugi.test" ], "ip": [ "45.0.0.6" ] }
  ],
  "runtime": { "wan_dns": [ "45.0.0.2" ], "ipv6": false, "mem_total_kb": 262144 }
}
EOF

echo "== global mode"
if start_mayhem "$WORK/global.json"; then
	expect "no rule -> proxy" 45.0.0.2 http://45.0.0.2:8080/
	expect "exclusion domain -> xray direct" 45.0.0.1 -H 'Host: gosuslugi.test' http://45.0.0.2:8080/
	expect "exclusion IP -> kernel direct" 192.168.1.2 http://45.0.0.6:8080/
	expect_dns "exclusion domain -> domestic DNS" client 1.1.1.1 53 gosuslugi.test 45.0.0.2
	expect_dns "other domain -> remote DNS" client 1.1.1.1 53 anything.test 45.0.0.7
fi
stop_mayhem

ip netns exec router nft list table inet mayhem >/dev/null 2>&1 &&
	bad "rules removed on stop" || ok "rules removed on stop"
ip netns exec router ip rule | grep -q 'lookup 109' &&
	bad "policy rule removed on stop" || ok "policy rule removed on stop"

[ "$fail" = 0 ] && echo "netns: all tests passed" || echo "netns: some tests failed"
exit "$fail"
