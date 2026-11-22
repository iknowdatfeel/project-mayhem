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

mkdir -p "$T/run" "$T/uci" "$T/save" "$T/lib" "$T/bin" "$T/proc"

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

env MAYHEM_RUN_DIR="$T/run" MAYHEM_UCI_DIR="$T/uci" MAYHEM_UCI_SAVE_DIR="$T/save" \
	MAYHEM_XRAY_BIN="$T/bin/xray" MAYHEM_LIB_DIR="$T/lib" MAYHEM_INIT="$T/bin/init" MAYHEM_RPC_CHILD=1 STUB="$T" MAYHEM_PROC="$T/proc" \
	"$UCODE" -L "$ROOT/mayhem/files/usr/share/ucode/*.uc" "$ROOT/tests/select.uc" \
	"$ROOT/luci-app-mayhem/root/usr/share/rpcd/ucode/luci.mayhem"
rc=$?

# The config cannot be saved (a read-only file system): xray, told the
# choice already, goes back to the one it had; nodes.json and the overrides
# keep it too.
mkdir -p "$T/ro"
if mount -t tmpfs tmpfs "$T/ro" 2>/dev/null; then
	cp "$T/uci/mayhem" "$T/ro/"
	mount -o remount,ro "$T/ro"
	rm -f "$T/xray.log"
	printf 'bal-pool n-pool-a\n' > "$T/run/running.overrides"
	cp "$T/run/running.overrides" "$T/run/overrides"
	printf '{"sections":{"pool":{"type":"proxy","mode":"auto","balancer":"bal-pool","pool":true,"override":"n-pool-a","nodes":[{"tag":"n-pool-a","name":"A","protocol":"vless"},{"tag":"n-pool-b","name":"B","protocol":"vless"}]}}}' > "$T/run/nodes.json"
	cp "$T/run/nodes.json" "$T/nodes.before"
	# shellcheck disable=SC2016 # ucode, not the shell
	out="$(env MAYHEM_RUN_DIR="$T/run" MAYHEM_UCI_DIR="$T/ro" MAYHEM_UCI_SAVE_DIR="$T/save" \
		MAYHEM_XRAY_BIN="$T/bin/xray" MAYHEM_LIB_DIR="$T/lib" MAYHEM_INIT="$T/bin/init" MAYHEM_RPC_CHILD=1 \
		"$UCODE" -L "$ROOT/mayhem/files/usr/share/ucode/*.uc" -e '
			const fs = require("fs");
			fs.writefile(getenv("MAYHEM_RUN_DIR") + "/xray.pid", fs.readlink("/proc/self") + "\n");
			fs.writefile(getenv("MAYHEM_RUN_DIR") + "/active", "");
			const p = loadfile(ARGV[0])()["luci.mayhem"];
			print(sprintf("%J", p.select_node.call({ args: { section: "pool", tag: "n-pool-b" } })));
		' "$ROOT/luci-app-mayhem/root/usr/share/rpcd/ucode/luci.mayhem" 2>&1)"
	sleep 0.5
	umount "$T/ro"
	case "$out" in *"could not be saved"*) said=1 ;; *) said=0 ;; esac
	if [ "$said" = 1 ] && [ "$(tail -n 1 "$T/xray.log" 2>/dev/null)" = "api bo --server=127.0.0.1:12780 -b bal-pool n-pool-a" ] &&
		cmp -s "$T/run/nodes.json" "$T/nodes.before" && [ "$(cat "$T/run/overrides")" = "bal-pool n-pool-a" ]; then
		echo "ok   select: a choice that cannot be saved is taken back in xray"
	else
		echo "FAIL select: not saved: $out; xray $(tr '\n' ';' < "$T/xray.log" 2>/dev/null); overrides $(cat "$T/run/overrides")"
		rc=1
	fi
else
	echo "skip select: not saved (no tmpfs mount here)"
fi

exit "$rc"
