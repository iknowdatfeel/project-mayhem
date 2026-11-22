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
# The provider's DNS for dnsmasq (every minute): files of the test, no dnsmasq.
mkdir -p "$T/dnsmasq"
export MAYHEM_DNS_SERVERS="$T/dnsmasq/mayhem.servers" MAYHEM_RESOLV_AUTO="$T/resolv.conf.auto"
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
printf '#!/bin/sh\nexit 1\n' > "$T/bin/pidof"
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

# A watchdog that takes long (a hung xray: curl waits for it) does not hold
# the checks of the servers either.
: > "$T/log"
{
	cat "$T/lib/lib.sh"
	# shellcheck disable=SC2016
	echo 'mayhem_watchdog() { echo "watchdog start" >> "$STUB/log"; /bin/sleep 1.5; echo "watchdog end" >> "$STUB/log"; }'
} > "$T/lib/lib2.sh"
mv "$T/lib/lib2.sh" "$T/lib/lib.sh"
PATH="$T/bin:$PATH" MAYHEM_SUB=sub MAYHEM_UPDATE=upd sh "$FILES/usr/libexec/mayhem/scheduler" &
pid=$!
/bin/sleep 2.5
kill "$pid" 2>/dev/null
wait "$pid" 2>/dev/null
checks_during="$(awk '/watchdog start/ { on = 1 } /watchdog end/ { on = 0 } on && /^health/ { n++ } END { print n + 0 }' "$T/log")"
if [ "$checks_during" -ge 3 ]; then
	ok "the checks go on while the watchdog runs"
else
	bad "checks during the watchdog: $checks_during / $(cat "$T/log")"
fi

# The provider's DNS servers follow resolv.conf.auto every minute without a
# reload; dnsmasq gets a HUP only when the file changed.
{
	cat "$T/lib/lib.sh"
	echo 'mayhem_watchdog() { :; }'
} > "$T/lib/lib2.sh"
mv "$T/lib/lib2.sh" "$T/lib/lib.sh"
printf '@ISP@\n' > "$T/run/dns.xray"
echo 'nameserver 10.9.9.9' > "$T/resolv.conf.auto"
echo 'server=10.9.9.9' > "$T/dnsmasq/mayhem.servers"
: > "$T/hups"
# shellcheck disable=SC2016
sh -c 'trap "echo hup >> \"$1/hups\"" HUP; while :; do /bin/sleep 0.05; done' sh "$T" &
dnsmasq_pid=$!
printf '#!/bin/sh\necho %s\n' "$dnsmasq_pid" > "$T/bin/pidof"
chmod +x "$T/bin/pidof"
PATH="$T/bin:$PATH" MAYHEM_SUB=sub MAYHEM_UPDATE=upd sh "$FILES/usr/libexec/mayhem/scheduler" &
pid=$!
/bin/sleep 1.5
same_hups="$(grep -c hup "$T/hups")"
echo 'nameserver 10.7.7.7' > "$T/resolv.conf.auto"
/bin/sleep 1.5
kill "$pid" 2>/dev/null
wait "$pid" 2>/dev/null
kill "$dnsmasq_pid" 2>/dev/null
if [ "$same_hups" = 0 ]; then ok "unchanged provider DNS: no HUP for dnsmasq"; else bad "unchanged provider DNS: $same_hups HUPs"; fi
if [ "$(cat "$T/dnsmasq/mayhem.servers")" = 'server=10.7.7.7' ] && [ "$(grep -c hup "$T/hups")" -ge 1 ]; then
	ok "new provider DNS: the servers file follows without a reload"
else
	bad "new provider DNS: $(cat "$T/dnsmasq/mayhem.servers"), HUPs $(grep -c hup "$T/hups")"
fi

rm -f "$T/run/dns.xray"

# xray's metrics (/debug/vars) once a minute for the watchdog and the memory
# trim together, with the real functions of lib.sh and a running "xray".
{
	cat "$FILES/usr/share/mayhem/lib.sh"
	for f in mayhem_tunnels_check mayhem_conn_fold mayhem_auto_update mayhem_dns_catchup; do
		echo "$f() { :; }"
	done
} > "$T/lib/lib.sh"
cp "$(command -v sleep)" "$T/xray"
"$T/xray" 30 &
xpid=$!
echo "$xpid" > "$T/run/xray.pid"
cat > "$T/bin/curl" <<'EOF2'
#!/bin/sh
for a; do url="$a"; done
echo "$url" >> "$STUB/curl.log"
case "$url" in */debug/vars) echo '{"memstats":{"HeapIdle":0,"HeapReleased":0}}' ;; esac
EOF2
chmod +x "$T/bin/curl"
: > "$T/curl.log"
PATH="$T/bin:$PATH" MAYHEM_SUB=sub MAYHEM_UPDATE=upd MAYHEM_WATCHDOG=1 MAYHEM_WATCHDOG_MEM=90 MAYHEM_DNSMASQ_INIT=/bin/false \
	sh "$FILES/usr/libexec/mayhem/scheduler" &
pid=$!
/bin/sleep 0.45
kill "$pid" 2>/dev/null
wait "$pid" 2>/dev/null
kill "$xpid" 2>/dev/null
n="$(grep -c '/debug/vars$' "$T/curl.log")"
if [ "$n" = 1 ]; then ok "one minute: /debug/vars asked once"; else bad "one minute: /debug/vars asked $n times"; fi
rm -f "$T/bin/curl"

# The nightly update of Mayhem: an install.pid whose process is gone does not
# hold it off (and goes); one of a live process does.
mkdir -p "$T/au/bin" "$T/au/run"
cat > "$T/au/bin/uci" <<'EOF2'
#!/bin/sh
case "$*" in
	*settings.auto_update*) echo 1 ;;
	*geo.update_hour*) echo 4 ;;
esac
EOF2
cat > "$T/au/bin/date" <<'EOF2'
#!/bin/sh
case "$1" in +%H) echo 04 ;; +%M) echo 45 ;; *) echo 20261116 ;; esac
EOF2
# shellcheck disable=SC2016
printf '#!/bin/sh\necho "$1" > "%s/au/started"\n' "$T" > "$T/au/bin/cli"
chmod +x "$T/au/bin/"*
auto_update() {
	rm -f "$T/au/started"
	# shellcheck disable=SC2016 # expanded by the inner shell
	PATH="$T/au/bin:$PATH" MAYHEM_RUN_DIR="$T/au/run" MAYHEM_LIB_DIR="$FILES/usr/share/mayhem" MAYHEM_CLI="$T/au/bin/cli" \
		sh -c '. "$MAYHEM_LIB_DIR/lib.sh"; mayhem_auto_update'
	/bin/sleep 0.3
}
echo 999999 > "$T/au/run/install.pid"
auto_update
if [ "$(cat "$T/au/started" 2>/dev/null)" = auto-update ] && [ ! -e "$T/au/run/install.pid" ]; then
	ok "auto-update: a pid of a process that is gone does not hold it off"
else
	bad "auto-update with a stale install.pid: started $(cat "$T/au/started" 2>/dev/null), pid file $(cat "$T/au/run/install.pid" 2>/dev/null)"
fi
echo "$$" > "$T/au/run/install.pid"
auto_update
if [ ! -e "$T/au/started" ] && [ -e "$T/au/run/install.pid" ]; then
	ok "auto-update: a running install holds it off"
else
	bad "auto-update next to a running install: started $(cat "$T/au/started" 2>/dev/null)"
fi
rm -f "$T/au/run/install.pid"
echo "$$" > "$T/au/run/auto-update.pid"
auto_update
if [ ! -e "$T/au/started" ]; then
	ok "auto-update: one that still runs is not started again"
else
	bad "auto-update next to a running one: started $(cat "$T/au/started" 2>/dev/null)"
fi
rm -f "$T/au/run/auto-update.pid"

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

# A stop while health.uc waits for a dead server: the scheduler goes at once
# and the run with it, nothing of it is left.
cat > "$T/bin/sleep" <<'EOF2'
#!/bin/sh
/bin/sleep "$(awk -v s="$1" 'BEGIN { print s / 100 }')"
EOF2
cat > "$T/bin/ucode" <<'EOF2'
#!/bin/sh
case "$*" in
	*health.uc*) echo $$ > "$STUB/hc.pid"; exec /bin/sleep 30 ;;
esac
exit 0
EOF2
chmod +x "$T/bin/sleep" "$T/bin/ucode"
rm -f "$T/hc.pid"
PATH="$T/bin:$PATH" MAYHEM_SUB=sub MAYHEM_UPDATE=upd sh "$FILES/usr/libexec/mayhem/scheduler" &
pid=$!
for _ in 1 2 3 4 5 6 7 8 9 10; do [ -s "$T/hc.pid" ] && break; /bin/sleep 0.2; done
t0="$(date +%s%N)"
kill "$pid" 2>/dev/null
wait "$pid" 2>/dev/null
ms=$((($(date +%s%N) - t0) / 1000000))
/bin/sleep 0.3
hc="$(cat "$T/hc.pid" 2>/dev/null)"
if [ -n "$hc" ] && [ "$ms" -lt 1000 ] && ! kill -0 "$hc" 2>/dev/null; then
	ok "TERM stops the scheduler during a long check, the check with it"
else
	bad "TERM during a check: $ms ms, check ${hc:-not started} $(kill -0 "$hc" 2>/dev/null && echo still runs)"
fi
[ -n "$hc" ] && kill "$hc" 2>/dev/null

# Nothing to download: sub.uc and update.uc write when they are next due
# (an hour on), and the minutes after start no ucode for them. A saved
# config, a new subscription after a reload, or the time come: a run.
cat > "$T/bin/ucode" <<'EOF2'
#!/bin/sh
now="$(date +%s)"
case "$*" in
	*update\ --no-wait*) echo sub >> "$STUB/runs"; echo "$((now + 3600)) $now" > "$MAYHEM_RUN_DIR/sub.next" ;;
	*update.uc\ due*) echo upd >> "$STUB/runs"; echo "$((now + ${DATA_IN:-3600})) $now" > "$MAYHEM_RUN_DIR/data.next" ;;
esac
exit 0
EOF2
chmod +x "$T/bin/ucode"
printf "config settings 'settings'\n" > "$T/mayhem"
touch -d '-1 hour' "$T/mayhem"
rm -f "$T/runs" "$T/run/sub.next" "$T/run/data.next" "$T/run/subs.new" "$T/run/data.pending"
runs() { n="$(grep -c "^$1\$" "$T/runs" 2>/dev/null)"; echo "${n:-0}"; }
PATH="$T/bin:$PATH" MAYHEM_SUB=sub MAYHEM_UPDATE=upd MAYHEM_UCI_DIR="$T" sh "$FILES/usr/libexec/mayhem/scheduler" &
pid=$!
# a minute is 0.6 s here: four of them
/bin/sleep 2.5
if [ "$(runs sub)" = 1 ] && [ "$(runs upd)" = 1 ]; then
	ok "nothing due: sub.uc and update.uc once in four minutes"
else
	bad "nothing due: sub.uc $(runs sub) times, update.uc $(runs upd) times"
fi
/bin/sleep 1.1
touch "$T/mayhem"
/bin/sleep 1.3
if [ "$(runs sub)" = 2 ] && [ "$(runs upd)" = 2 ]; then
	ok "a saved config: both run in the next minute"
else
	bad "after a saved config: sub.uc $(runs sub), update.uc $(runs upd)"
fi
/bin/sleep 1.1
echo mysub > "$T/run/subs.new"
/bin/sleep 1.3
if [ "$(runs sub)" = 3 ] && [ "$(runs upd)" = 2 ]; then
	ok "a new subscription: sub.uc runs, update.uc does not"
else
	bad "a new subscription: sub.uc $(runs sub), update.uc $(runs upd)"
fi
# due now: a run every minute
echo "$(($(date +%s) - 1)) $(date +%s)" > "$T/run/data.next"
/bin/sleep 1.3
if [ "$(runs upd)" = 3 ]; then
	ok "the time come: update.uc runs"
else
	bad "update.uc due now: $(runs upd) runs"
fi
kill "$pid" 2>/dev/null
wait "$pid" 2>/dev/null

rm -rf "$T"
[ "$fail" = 0 ] && echo "scheduler tests passed"
exit "$fail"
