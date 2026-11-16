#!/bin/sh
# "Stop" on the dashboard holds until Mayhem is started again: the real rpcd
# method rename_section then saves without a reload of the
# service; after "start" it reloads it again. The init script is a stand-in
# that logs what it is asked.
#   UCODE=ucode tests/stopped.sh

set -u

ROOT="$(cd "$(dirname "$0")/.." && pwd)"
UCODE="${UCODE:-ucode}"
T="$(mktemp -d)"
trap 'rm -rf "$T"' EXIT

mkdir -p "$T/run" "$T/uci" "$T/save" "$T/lib" "$T/bin"

cat > "$T/uci/mayhem" <<'EOF'
config settings 'settings'
	option enabled '1'

config pool 'pool'
	list link 'vless://id@a.example:443#A'
	option select 'auto'

config section 'video'
	option type 'proxy'
	list domain 'example.org'
EOF

cat > "$T/bin/init" <<EOF
#!/bin/sh
echo "init \$*" >> "$T/init.log"
exit 0
EOF
printf '#!/bin/sh\nexit 0\n' > "$T/bin/xray"
: > "$T/lib/lib.sh"
chmod +x "$T/bin/init" "$T/bin/xray"

exec env MAYHEM_RUN_DIR="$T/run" MAYHEM_UCI_DIR="$T/uci" MAYHEM_UCI_SAVE_DIR="$T/save" \
	MAYHEM_XRAY_BIN="$T/bin/xray" MAYHEM_LIB_DIR="$T/lib" MAYHEM_INIT="$T/bin/init" MAYHEM_RPC_CHILD=1 STUB="$T" \
	"$UCODE" -L "$ROOT/mayhem/files/usr/share/ucode/*.uc" "$ROOT/tests/stopped.uc" \
	"$ROOT/luci-app-mayhem/root/usr/share/rpcd/ucode/luci.mayhem"
