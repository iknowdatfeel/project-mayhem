#!/bin/sh
# A server chosen on the dashboard and a fallback chain set there, through the
# real rpcd methods select_node and set_select (not a copy of their logic):
# xray, lib.sh and the init script are stand-ins that log what they are asked.
#   UCODE=ucode tests/select.sh

set -u

ROOT="$(cd "$(dirname "$0")/.." && pwd)"
UCODE="${UCODE:-ucode}"
T="$(mktemp -d)"
trap 'rm -rf "$T"' EXIT

mkdir -p "$T/run" "$T/uci" "$T/save" "$T/lib" "$T/bin"

cat > "$T/uci/mayhem" <<'EOF'
config settings 'settings'
	option enabled '1'
	option reconnect_epoch '5'

config subscription 'mysub'
	option url 'http://example.invalid/sub'

config pool 'pool'
	list link 'vless://id@a.example:443#A'
	list link 'vless://id@b.example:443#B'
	option select 'auto'
EOF

cat > "$T/bin/xray" <<EOF
#!/bin/sh
echo "\$*" >> "$T/xray.log"
exit 0
EOF

cat > "$T/bin/init" <<EOF
#!/bin/sh
echo "init \$*" >> "$T/init.log"
exit 0
EOF

cat > "$T/lib/lib.sh" <<EOF
mayhem_lock() { :; }
mayhem_unlock() { :; }
mayhem_net_generation() { echo net_generation >> "$T/lib.log"; return 0; }
mayhem_dns_servers() { echo "dns \$*" >> "$T/lib.log"; }
EOF

chmod +x "$T/bin/xray" "$T/bin/init"

exec env MAYHEM_RUN_DIR="$T/run" MAYHEM_UCI_DIR="$T/uci" MAYHEM_UCI_SAVE_DIR="$T/save" \
	MAYHEM_XRAY_BIN="$T/bin/xray" MAYHEM_LIB_DIR="$T/lib" MAYHEM_INIT="$T/bin/init" MAYHEM_RPC_CHILD=1 STUB="$T" \
	"$UCODE" -L "$ROOT/mayhem/files/usr/share/ucode/*.uc" "$ROOT/tests/select.uc" \
	"$ROOT/luci-app-mayhem/root/usr/share/rpcd/ucode/luci.mayhem"
