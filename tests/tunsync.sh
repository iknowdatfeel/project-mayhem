#!/bin/sh
# Reload with tunnel sections (mayhem_tunnels_sync): a tunnel that stays keeps
# its rule and its route, a new one gets its rule, one that is gone loses
# its rule and its table. ip, awg and ping are stand-ins.
#   tests/tunsync.sh

set -u

ROOT="$(cd "$(dirname "$0")/.." && pwd)"
FILES="$ROOT/mayhem/files"
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

mkdir -p "$T/bin" "$T/run"
export MAYHEM_RUN_DIR="$T/run" MAYHEM_LIB_DIR="$FILES/usr/share/mayhem" STUB="$T"

# ip: rules kept in $STUB/rules4 and rules6 (as `ip rule show` prints them),
# every command that changes something logged.
cat > "$T/bin/ip" <<'EOF'
#!/bin/sh
fam=4
case "$1" in -4) shift ;; -6) fam=6; shift ;; esac
r="$STUB/rules$fam"
touch "$r"
case "$1 $2" in
	"rule show")
		cat "$r" ;;
	"rule add")
		# fwmark M table T priority P
		echo "$8:	from all fwmark $4 lookup $6" >> "$r"
		echo "ip -$fam $*" >> "$STUB/ip.log" ;;
	"rule del")
		grep -qF "fwmark $4 lookup $6" "$r" || exit 2
		grep -vF "fwmark $4 lookup $6" "$r" > "$r.t"; mv "$r.t" "$r"
		echo "ip -$fam $*" >> "$STUB/ip.log" ;;
	*)
		echo "ip -$fam $*" >> "$STUB/ip.log" ;;
esac
EOF
printf '#!/bin/sh\nexit 0\n' > "$T/bin/ping"
printf '#!/bin/sh\nexit 0\n' > "$T/bin/logger"
# awg: every tunnel had a handshake just now
# shellcheck disable=SC2016
printf '#!/bin/sh\necho "peer $(date +%%s)"\n' > "$T/bin/awg"
chmod +x "$T/bin/"*
export PATH="$T/bin:$PATH"

# The devices: present and up.
mkdir -p "$T/sys"
for d in awg1 awg2 awg3; do mkdir -p "$T/sys/$d"; echo unknown > "$T/sys/$d/operstate"; done

lib() { sh -c ". '$MAYHEM_LIB_DIR/lib.sh'; mayhem_tunnel_ok() { [ -d '$T/sys/'\"\$1\" ]; }; mayhem_select() { :; }; $1"; }

printf 'a awg1 0x4000001 111 0\nb awg2 0x4000002 112 1\n' > "$T/run/tunnels"
lib "mayhem_tunnels_up" 2>/dev/null
cp "$T/run/tunnels" "$T/run/running.tunnels"
: > "$T/ip.log"
echo up > "$T/run/tunnel.a"

# b goes, c comes, a stays.
printf 'a awg1 0x4000001 111 0\nc awg3 0x4000003 113 0\n' > "$T/run/tunnels"
lib "mayhem_tunnels_sync '$T/run/running.tunnels' '$T/run/tunnels'" 2>/dev/null

if grep -E 'rule del .*table 111|route flush table 111' "$T/ip.log" >/dev/null; then
	bad "a tunnel that stays lost its rule or route: $(cat "$T/ip.log")"
else
	ok "a tunnel that stays keeps its rule and route"
fi
if grep -q 'fwmark 0x4000003/0x40000ff lookup 113' "$T/rules4"; then ok "a new tunnel gets its rule"; else bad "new tunnel: $(cat "$T/rules4")"; fi
if ! grep -q 'lookup 112' "$T/rules4" && ! grep -q 'lookup 112' "$T/rules6" && grep -q 'route flush table 112' "$T/ip.log"; then
	ok "a tunnel that is gone loses its rule and table"
else
	bad "gone tunnel: $(cat "$T/rules4" "$T/rules6") / $(cat "$T/ip.log")"
fi
if [ "$(grep -c 'lookup 111' "$T/rules4")" = 1 ]; then ok "no rule twice"; else bad "rules: $(cat "$T/rules4")"; fi
if [ "$(cat "$T/run/tunnel.a" 2>/dev/null)" = up ] && [ "$(cat "$T/run/tunnel.c" 2>/dev/null)" = up ] && [ ! -f "$T/run/tunnel.b" ]; then
	ok "states: kept, new, gone"
else
	bad "states: $(ls "$T/run")"
fi

rm -rf "$T"
[ "$fail" = 0 ] && echo "tunnel sync tests passed"
exit "$fail"
