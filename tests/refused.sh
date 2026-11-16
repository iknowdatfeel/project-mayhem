#!/bin/sh
# Servers xray refuses, with stand-ins for xray, logger, ip, nft and sleep:
# live.uc adds them one by one when the batch fails and notes the refused
# ones in refused.json (exit code 2); xray-run notes the server xray names at
# a failed start and reloads once, waits longer after each failed start; the
# error of a config is tested once.
#   UCODE=ucode tests/refused.sh

set -u

ROOT="$(cd "$(dirname "$0")/.." && pwd)"
FILES="$ROOT/mayhem/files"
UCODE="${UCODE:-ucode}"
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

mkdir -p "$T/bin" "$T/run" "$T/dnsmasq"
export MAYHEM_RUN_DIR="$T/run" MAYHEM_LIB_DIR="$FILES/usr/share/mayhem" MAYHEM_XRAY_BIN="$T/bin/xray" \
	MAYHEM_DNS_SERVERS="$T/dnsmasq/mayhem.servers" MAYHEM_RESOLV_AUTO="$T/resolv.conf.auto" \
	MAYHEM_INIT="$T/bin/init" STUB="$T"

echo 'nameserver 10.9.9.9' > "$T/resolv.conf.auto"

# xray: "api ado FILE" fails on a server of protocol "bogus" (the batch stops
# there); "run -test" names it; "run" exits at once.
cat > "$T/bin/xray" <<'EOF'
#!/bin/sh
case "$1 $2" in
	"api ado")
		for f; do :; done
		echo "ado $(grep -o '"tag": *"[^"]*"' "$f" | sed 's/.*"\([^"]*\)"$/\1/' | tr '\n' ' ')" >> "$STUB/calls"
		if grep -q '"bogus"' "$f"; then
			echo 'failed to build outbound: unknown protocol "bogus"'
			exit 1
		fi
		;;
	"api "*) echo "$2" >> "$STUB/calls" ;;
	"run -test")
		echo "test" >> "$STUB/calls"
		echo 'Failed to start: main: failed to load config files > infra/conf: failed to build outbound config with tag n-main-bad > unknown protocol "bogus"'
		exit 23
		;;
	"run -c") exit 23 ;;
	"version "*|"version") echo "Xray 26.10.31 (Xray, Penetrates Everything.)" ;;
esac
exit 0
EOF
for c in logger pidof; do printf '#!/bin/sh\nexit 0\n' > "$T/bin/$c"; done
for c in ip nft uci; do printf '#!/bin/sh\nexit 1\n' > "$T/bin/$c"; done
# shellcheck disable=SC2016 # $1 and $STUB of the stand-ins
printf '#!/bin/sh\necho "$1" >> "$STUB/sleeps"\nexit 0\n' > "$T/bin/sleep"
# shellcheck disable=SC2016
printf '#!/bin/sh\necho "$1" >> "$STUB/init"\nexit 0\n' > "$T/bin/init"
chmod +x "$T/bin/"*

uc() { "$UCODE" -L "$FILES/usr/share/ucode/*.uc" ${UCODE_LIB:+-L "$UCODE_LIB"} "$@"; }

GOOD='{ "tag": "n-main-good", "protocol": "freedom" }'
BAD='{ "tag": "n-main-bad", "protocol": "bogus" }'
OLD='{ "tag": "n-main-old", "protocol": "freedom" }'
cfg() { printf '{ "outbounds": [ %s ], "routing": { "rules": [], "balancers": [] } }\n' "$1"; }

R="$T/run"
echo key > "$R/xray.key"
echo key > "$R/running.xray.key"
: > "$R/overrides"
: > "$R/running.overrides"
cfg "$OLD" > "$R/running.xray.json"
cfg "$OLD, $GOOD, $BAD" > "$R/xray.json"
cat > "$R/nodes.json" <<'EOF'
{ "sections": { "main": { "type": "proxy", "nodes": [ { "tag": "n-main-good", "name": "Good" }, { "tag": "n-main-bad", "name": "Bad" } ] } } }
EOF

live() { PATH="$T/bin:$PATH" uc "$FILES/usr/share/mayhem/live.uc" >/dev/null 2>&1; }

: > "$T/calls"
live
rc=$?
if [ "$rc" = 2 ] && grep -q '"n-main-bad"' "$R/refused.json" 2>/dev/null &&
   uc -e "const r = json(require('fs').readfile('$R/refused.json'))['n-main-bad'];
	exit(r.name == 'Bad' && index(r.error, 'unknown protocol') >= 0 && r.at > 0 ? 0 : 1);" &&
   grep -q '^ado n-main-good $' "$T/calls" && ! grep -q 'n-main-good' "$R/refused.json" &&
   grep -q 'n-main-old' "$R/running.xray.json" && ! grep -q 'n-main-good' "$R/running.xray.json"; then
	ok "live: a refused batch goes one by one, the refused server noted, exit 2"
else
	bad "live: rc $rc, calls: $(tr '\n' '|' < "$T/calls"), refused: $(cat "$R/refused.json" 2>/dev/null)"
fi

# Built again without it: taken.
cfg "$OLD, $GOOD" > "$R/xray.json"
: > "$T/calls"
live
rc=$?
if [ "$rc" = 0 ] && cmp -s "$R/xray.json" "$R/running.xray.json"; then
	ok "live: the config without the refused server goes in"
else
	bad "live, second pass: rc $rc, calls: $(tr '\n' '|' < "$T/calls")"
fi

# The error of a config is tested once while the config is the same.
rm -f "$R/xray.error" "$R/xray.error.sum"
: > "$T/calls"
(
	PATH="$T/bin:$PATH"
	. "$FILES/usr/share/mayhem/lib.sh"
	mayhem_xray_error
	mayhem_xray_error
)
n1="$(grep -c '^test$' "$T/calls")"
cfg "$GOOD" > "$R/running.xray.json"
( PATH="$T/bin:$PATH"; . "$FILES/usr/share/mayhem/lib.sh"; mayhem_xray_error )
n2="$(grep -c '^test$' "$T/calls")"
if [ "$n1" = 1 ] && [ "$n2" = 2 ] && grep -q 'n-main-bad' "$R/xray.error"; then
	ok "xray error: tested once per config"
else
	bad "xray error: run -test $n1 then $n2 times"
fi

# xray-run: xray does not start, names the server; it is noted, Mayhem
# reloads once, and procd's next start comes later each time.
xray_run() { PATH="$T/bin:$PATH" sh "$FILES/usr/libexec/mayhem/xray-run" >/dev/null 2>&1; }

rm -f "$R/refused.json" "$R/xray.error" "$R/xray.error.sum" "$R/xray.fails" "$T/sleeps" "$T/init"
cfg "$GOOD, $BAD" > "$R/xray.json"
xray_run
/bin/sleep 1
if grep -q '"n-main-bad"' "$R/refused.json" 2>/dev/null && [ "$(cat "$T/init" 2>/dev/null)" = reload ]; then
	ok "xray-run: the server xray names is noted, one reload"
else
	bad "xray-run: refused $(cat "$R/refused.json" 2>/dev/null), init $(cat "$T/init" 2>/dev/null)"
fi

xray_run
/bin/sleep 1
if [ "$(cat "$T/init" 2>/dev/null)" = reload ]; then
	ok "xray-run: a server noted already is no reason for another reload"
else
	bad "xray-run: reloads $(tr '\n' ' ' < "$T/init")"
fi

echo 10 > "$R/xray.fails"
xray_run
if [ "$(grep -v '^0' "$T/sleeps" | tr '\n' ' ')" = "5 10 300 " ] && [ "$(cat "$R/xray.fails")" = 11 ]; then
	ok "xray-run: failed starts wait 5 s, twice that, up to 5 minutes"
else
	bad "xray-run: waits $(grep -v '^0' "$T/sleeps" | tr '\n' ' '), fails $(cat "$R/xray.fails")"
fi

rm -rf "$T"
exit "$fail"
