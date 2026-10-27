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

mkdir -p "$FIX/uci" "$FIX/uci-save" "$FIX/run" "$FIX/geo" "$FIX/lists" "$FIX/subs" "$FIX/dat"
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

# Active connections: the kernel's table, DHCP names, the folded log.
cat > "$FIX/conntrack" <<'CT'
ipv4     2 tcp      6 7431 ESTABLISHED src=192.168.1.187 dst=142.250.74.110 sport=48398 dport=443 packets=10 bytes=1000 src=142.250.74.110 dst=192.168.1.187 sport=443 dport=48398 packets=10 bytes=15000000 [ASSURED] mark=268435456 zone=0 use=2
ipv4     2 tcp      6 7431 ESTABLISHED src=192.168.1.187 dst=142.250.74.110 sport=48399 dport=443 packets=10 bytes=1000 src=142.250.74.110 dst=192.168.1.187 sport=443 dport=48399 packets=10 bytes=2000000 [ASSURED] mark=268435456 zone=0 use=2
ipv4     2 udp      17 170 src=192.168.1.187 dst=142.250.74.110 sport=48400 dport=443 packets=10 bytes=1000 src=142.250.74.110 dst=192.168.1.187 sport=443 dport=48400 packets=10 bytes=900000 [ASSURED] mark=268435456 zone=0 use=2
ipv4     2 tcp      6 7431 ESTABLISHED src=192.168.1.20 dst=77.88.55.88 sport=6000 dport=443 packets=5 bytes=900 src=77.88.55.88 dst=203.0.113.5 sport=443 dport=6000 packets=5 bytes=90000 [ASSURED] mark=0 zone=0 use=2
ipv4     2 tcp      6 7431 ESTABLISHED src=192.168.1.20 dst=77.88.55.88 sport=6001 dport=443 packets=5 bytes=900 src=77.88.55.88 dst=203.0.113.5 sport=443 dport=6001 packets=5 bytes=9000 [ASSURED] mark=0 zone=0 use=2
ipv6     10 tcp      6 7431 ESTABLISHED src=fd00:0000:0000:0000:0a1b:2c3d:4e5f:0001 dst=2a00:1450:4010:0c0e:0000:0000:0000:0065 sport=50001 dport=443 packets=5 bytes=700 src=2a00:1450:4010:0c0e:0000:0000:0000:0065 dst=fd00:0000:0000:0000:0a1b:2c3d:4e5f:0001 sport=443 dport=50001 packets=5 bytes=70000 [ASSURED] mark=268435456 zone=0 use=2
ipv4     2 tcp      6 7431 ESTABLISHED src=198.51.100.7 dst=203.0.113.5 sport=40001 dport=51413 packets=5 bytes=400 src=192.168.1.187 dst=198.51.100.7 sport=51413 dport=40001 packets=5 bytes=600000 [ASSURED] mark=0 zone=0 use=2
ipv4     2 tcp      6 100 TIME_WAIT src=192.168.1.20 dst=8.8.8.8 sport=6002 dport=443 packets=5 bytes=900 src=8.8.8.8 dst=203.0.113.5 sport=443 dport=6002 packets=5 bytes=900 mark=0 zone=0 use=2
ipv4     2 udp      17 20 src=192.168.1.20 dst=8.8.4.4 sport=5354 dport=53 packets=1 bytes=60 src=192.168.1.1 dst=192.168.1.20 sport=53 dport=5354 packets=1 bytes=120 mark=0 zone=0 use=2
CT
echo '1793030000 aa:bb:cc:dd:ee:ff 192.168.1.187 iPhone *' > "$FIX/leases"
printf '#!/bin/sh\nprintf "%%s\\n" "2: br-lan    inet 192.168.1.1/24 scope global br-lan" "3: wan    inet 203.0.113.5/24 scope global wan"\n' > "$FIX/addrs"
printf '#!/bin/sh\necho "fd00::a1b:2c3d:4e5f:1 dev br-lan lladdr aa:bb:cc:dd:ee:ff REACHABLE"\n' > "$FIX/neigh"
chmod +x "$FIX/addrs" "$FIX/neigh"
printf '%s\n' 'd 142.250.74.110 www.youtube.com' 'd 2a00:1450:4010:c0e::65 www.google.com' 'd 77.88.55.88 ya.ru' \
	"c tcp 192.168.1.187:48398 $(grep -o '"tag": *"n-[^"]*"' "$FIX/run/nodes.json" | head -n 1 | sed 's/.*"\(n-[^"]*\)"/\1/')" \
	"c tcp fd00::a1b:2c3d:4e5f:1:50001 $(grep -o '"tag": *"n-[^"]*"' "$FIX/run/nodes.json" | head -n 1 | sed 's/.*"\(n-[^"]*\)"/\1/')" \
	"c udp 192.168.1.187:48400 $(grep -o '"tag": *"n-[^"]*"' "$FIX/run/nodes.json" | head -n 1 | sed 's/.*"\(n-[^"]*\)"/\1/')" > "$FIX/run/conn.names"
: > "$FIX/run/conn.log"

MAYHEM_CONNTRACK="$FIX/conntrack" MAYHEM_LEASES="$FIX/leases" MAYHEM_ADDRS_CMD="$FIX/addrs" MAYHEM_NEIGH_CMD="$FIX/neigh" \
	UCODE="$UCODE" python3 "$ROOT/tests/luci/harness.py" "$1" "$FIX"
