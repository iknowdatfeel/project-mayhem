#!/bin/sh
# The scheduler: a download that takes long does not hold up the checks of
# the servers (health.uc every 20 s), and only one download runs at a time.
# ucode, sleep and the service are stand-ins; 20 s are 0.2 s here.
#   tests/scheduler.sh

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

mkdir -p "$T/bin" "$T/run" "$T/lib"
# lib.sh with the jobs of the minute left out
cp "$FILES/usr/share/mayhem/const.sh" "$T/lib/"
{
	cat "$FILES/usr/share/mayhem/lib.sh"
	for f in mayhem_tunnels_check mayhem_watchdog mayhem_mem_trim mayhem_conn_fold mayhem_auto_update mayhem_dns_catchup; do
		echo "$f() { :; }"
	done
} > "$T/lib/lib.sh"
: > "$T/lib/health.uc"
export MAYHEM_RUN_DIR="$T/run" MAYHEM_LIB_DIR="$T/lib" STUB="$T"
: > "$T/run/active"

# ucode: the subscriptions take 1.5 s; every run is logged.
cat > "$T/bin/ucode" <<'EOF'
#!/bin/sh
case "$*" in
	*health.uc*) echo "health $(date +%s%N)" >> "$STUB/log" ;;
	*update\ --no-wait*) echo "sub start" >> "$STUB/log"; /bin/sleep 1.5; echo "sub end" >> "$STUB/log" ;;
esac
exit 0
EOF
# sleep: a hundredth of the time
cat > "$T/bin/sleep" <<'EOF'
#!/bin/sh
/bin/sleep "$(awk -v s="$1" 'BEGIN { print s / 100 }')"
EOF
printf '#!/bin/sh\nexit 0\n' > "$T/bin/logger"
chmod +x "$T/bin/"*

PATH="$T/bin:$PATH" MAYHEM_SUB=sub MAYHEM_UPDATE=upd sh "$FILES/usr/libexec/mayhem/scheduler" &
pid=$!
/bin/sleep 2.5
kill "$pid" 2>/dev/null
wait "$pid" 2>/dev/null

checks_during="$(awk '/sub start/ { on = 1 } /sub end/ { on = 0 } on && /^health/ { n++ } END { print n + 0 }' "$T/log")"
starts="$(grep -c 'sub start' "$T/log")"

if [ "$checks_during" -ge 3 ]; then
	ok "the checks go on while a download runs"
else
	bad "checks during a download: $checks_during / $(cat "$T/log")"
fi
# a minute is 0.6 s here: more minutes passed than downloads started
if [ "$starts" -le 2 ]; then ok "one download at a time"; else bad "downloads started: $starts"; fi

# A stop: the scheduler goes at once on TERM, also while it sleeps (procd
# killed it 5 s later, its downloads with it).
cat > "$T/bin/sleep" <<'EOF2'
#!/bin/sh
/bin/sleep 5
EOF2
PATH="$T/bin:$PATH" MAYHEM_SUB=sub MAYHEM_UPDATE=upd sh "$FILES/usr/libexec/mayhem/scheduler" &
pid=$!
/bin/sleep 0.3
t0="$(date +%s%N)"
kill "$pid" 2>/dev/null
wait "$pid" 2>/dev/null
ms=$((($(date +%s%N) - t0) / 1000000))
if [ "$ms" -lt 1000 ]; then ok "TERM stops the scheduler while it sleeps"; else bad "TERM took $ms ms"; fi

rm -rf "$T"
[ "$fail" = 0 ] && echo "scheduler tests passed"
exit "$fail"
