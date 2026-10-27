#!/bin/sh
# URL test over kept-alive connections (warm.uc) against a fake SOCKS inbound
# (tests/warm/fake_socks.py on 127.0.0.1:12782): the number is the request over
# the open connection, not the handshakes; the connection is kept; errors are
# named like the single URL test; "now" checks at once; the process ends when
# the dashboard stops asking. Also the rpcd method "warm" that starts it.
#   UCODE=ucode tests/warm.sh      (needs ucode's socket module and python3)

set -u

ROOT="$(cd "$(dirname "$0")/.." && pwd)"
UCODE="${UCODE:-ucode}"
T="$(mktemp -d)"
fail=0
FAKE=""
DAEMON=""

cleanup() {
	[ -n "$DAEMON" ] && kill "$DAEMON" 2>/dev/null
	[ -n "$FAKE" ] && kill "$FAKE" 2>/dev/null
	pkill -f "$T/" 2>/dev/null
	rm -rf "$T"
}
trap cleanup EXIT

ok() { printf 'ok   %s\n' "$1"; }
bad() { printf 'FAIL %s\n' "$1"; fail=1; }

if ! "$UCODE" -e 'import * as s from "socket";' 2>/dev/null; then
	echo "skip: ucode has no socket module"
	exit 0
fi

mkdir -p "$T/run" "$T/bin"
cat > "$T/bin/ucode" <<EOF
#!/bin/sh
exec "$UCODE" -L "$ROOT/mayhem/files/usr/share/ucode/*.uc" "\$@"
EOF
chmod +x "$T/bin/ucode"
export PATH="$T/bin:$PATH" MAYHEM_RUN_DIR="$T/run" MAYHEM_WARM_PERIOD=2 MAYHEM_WARM_IDLE=4 MAYHEM_WARM_TIMEOUT=3
export MAYHEM_RPC_WARM="$ROOT/luci-app-mayhem/root/usr/share/mayhem-luci/warm.uc"

python3 "$ROOT/tests/warm/fake_socks.py" "$T/log" &
FAKE=$!
i=0
while ! grep -q listening "$T/log" 2>/dev/null; do
	i=$((i + 1)); [ "$i" -gt 50 ] && { echo "fake SOCKS did not start (port 12782 busy?)"; exit 1; }
	sleep 0.1
done

# xray "runs": warm.uc only checks that its pid is alive
echo "$FAKE" > "$T/run/xray.pid"
cat > "$T/run/nodes.json" <<'EOF'
{ "probe_url": "http://www.gstatic.com/generate_204",
  "sections": { "pool": { "nodes": [ { "tag": "n-fast", "address": "10.0.0.1" }, { "tag": "n-slow", "address": "10.0.0.2" },
    { "tag": "n-dead", "address": "10.0.0.3" }, { "tag": "n-503", "address": "10.0.0.4" },
    { "tag": "n-close", "address": "10.0.0.5" }, { "tag": "n-refused", "address": "10.0.0.6" } ] } } }
EOF

uc() { "$UCODE" -L "$ROOT/mayhem/files/usr/share/ucode/*.uc" "$@"; }
plugin="$ROOT/luci-app-mayhem/root/usr/share/rpcd/ucode/luci.mayhem"
warm_call() {
	uc -e "const p = loadfile('$plugin')()['luci.mayhem']; print(sprintf('%J', p.warm.call({ args: { now: $1 } })));"
}
field() { python3 -c 'import json,sys; d=json.load(open(sys.argv[1])); r=d["results"].get(sys.argv[2],{}); print(r.get(sys.argv[3], ""))' "$T/run/warm.json" "$1" "$2"; }

# The rpcd method starts the process and answers at once.
out="$(warm_call false)"
case "$out" in *'"ok": true'*'"tags": [ "n-503", "n-close", "n-dead", "n-fast", "n-refused", "n-slow" ]'*) ok "rpcd: warm answers with the servers it keeps" ;;
	*'"ok": true'*) ok "rpcd: warm answers" ;;
	*) bad "rpcd: warm: $out" ;; esac
sleep 0.5
DAEMON="$(cat "$T/run/warm.pid" 2>/dev/null)"
if [ -n "$DAEMON" ] && grep -q warm.uc "/proc/$DAEMON/cmdline" 2>/dev/null; then ok "rpcd: warm.uc started"; else bad "rpcd: warm.uc did not start"; fi

# a second call does not start another one
warm_call false >/dev/null
sleep 0.3
n="$(pgrep -fc "warm.uc")"
[ "$n" = 1 ] && ok "rpcd: one process" || bad "rpcd: $n processes"

# keep the "dashboard" asking for a while
for i in 1 2 3 4 5 6 7 8; do : > "$T/run/warm.alive"; sleep 1; done

fast="$(field n-fast ms)"; slow="$(field n-slow ms)"
[ -n "$fast" ] && [ "$fast" -ge 15 ] && [ "$fast" -lt 150 ] && ok "warm: request over the open connection ($fast ms, handshake 300)" || bad "warm: n-fast $fast ms"
[ -n "$slow" ] && [ "$slow" -ge 100 ] && [ "$slow" -lt 250 ] && ok "warm: slower server ($slow ms)" || bad "warm: n-slow $slow ms"
[ "$(field n-dead error)" = timeout ] && ok "warm: no answer is a timeout" || bad "warm: n-dead $(field n-dead error)"
[ "$(field n-503 error)" = "HTTP 503" ] && ok "warm: HTTP error" || bad "warm: n-503 $(field n-503 error)"
[ "$(field n-refused error)" = "no connection" ] && ok "warm: SOCKS refusal" || bad "warm: n-refused $(field n-refused error)"
close="$(field n-close ms)"
[ -n "$close" ] && ok "warm: a site without keep-alive still gets a number ($close ms)" || bad "warm: n-close $(field n-close error)"

conns="$(grep -c 'connect n-fast' "$T/log")"; reqs="$(grep -c 'request n-fast' "$T/log")"
[ "$conns" = 1 ] && [ "$reqs" -ge 4 ] && ok "warm: one connection, $reqs requests" || bad "warm: n-fast $conns connections, $reqs requests"

out="$(warm_call false)"
case "$out" in *'"n-fast": { "ms"'*) ok "rpcd: results in the answer" ;; *) bad "rpcd: no results: $out" ;; esac

# "now": with a long period, every server is asked again at once
kill "$DAEMON"; sleep 0.3
export MAYHEM_WARM_PERIOD=60
warm_call false >/dev/null
for i in 1 2 3; do : > "$T/run/warm.alive"; sleep 1; done
DAEMON="$(cat "$T/run/warm.pid")"
before="$(grep -c 'request n-fast' "$T/log")"
sleep 1.1
warm_call true >/dev/null
sleep 1
after="$(grep -c 'request n-fast' "$T/log")"
[ "$after" -gt "$before" ] && ok "warm: now checks at once" || bad "warm: now: $before -> $after requests"

# nobody asks: the process ends
i=0
while [ -d "/proc/$DAEMON" ] && grep -q warm.uc "/proc/$DAEMON/cmdline" 2>/dev/null; do
	i=$((i + 1)); [ "$i" -gt 80 ] && break
	sleep 0.1
done
[ "$i" -le 80 ] && ok "warm: ends when the dashboard stops asking" || bad "warm: still running"
DAEMON=""

# The dashboard opens again minutes later: the numbers of the last run are in
# the first answer, and the new run keeps them until it has its own.
python3 - "$T/run/warm.json" <<'PY'
import json, sys, time
d = json.load(open(sys.argv[1]))
for r in d['results'].values():
    r['at'] = int(time.time()) - 300
d['started'] = int(time.time()) - 400
json.dump(d, open(sys.argv[1], 'w'))
PY
old_fast="$(field n-fast ms)"
out="$(warm_call false)"
case "$out" in *'"n-fast": { "ms": '"$old_fast"*) ok "rpcd: the last numbers at once when the dashboard opens again" ;;
	*) bad "rpcd: no last numbers on a new run ($old_fast): $out" ;; esac
DAEMON="$(cat "$T/run/warm.pid" 2>/dev/null)"
sleep 0.3
case "$(field n-fast ms)" in "") bad "warm: a new run dropped the last numbers" ;; *) ok "warm: a new run keeps the last numbers" ;; esac
case "$(field n-dead ms)$(field n-dead error)" in "") ok "warm: errors of the last run are not kept" ;; *) bad "warm: n-dead kept: $(field n-dead error)" ;; esac
kill "$DAEMON" 2>/dev/null
DAEMON=""

exit $fail
