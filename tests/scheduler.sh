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
mkdir -p "$T/dnsmasq"
printf '@ISP@\n' > "$T/run/dns.xray"
echo 'nameserver 10.9.9.9' > "$T/resolv.conf.auto"
echo 'server=10.9.9.9' > "$T/dnsmasq/mayhem.servers"
: > "$T/hups"
# shellcheck disable=SC2016
sh -c 'trap "echo hup >> \"$1/hups\"" HUP; while :; do /bin/sleep 0.05; done' sh "$T" &
dnsmasq_pid=$!
printf '#!/bin/sh\necho %s\n' "$dnsmasq_pid" > "$T/bin/pidof"
chmod +x "$T/bin/pidof"
PATH="$T/bin:$PATH" MAYHEM_SUB=sub MAYHEM_UPDATE=upd MAYHEM_DNS_SERVERS="$T/dnsmasq/mayhem.servers" \
	MAYHEM_RESOLV_AUTO="$T/resolv.conf.auto" sh "$FILES/usr/libexec/mayhem/scheduler" &
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
