#!/bin/sh
# The state of the subscriptions lives in RAM and is empty after a reboot:
# the first `sub.uc update` that finds the cache on flash fresh writes the
# state from it, so the next ones (every minute) do not read the cache again.
#   UCODE=ucode tests/substate.sh

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

mkdir -p "$T/uci" "$T/run" "$T/subs" "$T/bin"
cat > "$T/uci/mayhem" <<'UCI'
config subscription 'mysub'
	option url 'http://example.invalid/sub'
	option update_interval '12'
UCI
# a download would be a call of curl: it is only counted
printf '#!/bin/sh\necho "$*" >> "%s/curl.log"\nexit 6\n' "$T" > "$T/bin/curl"
printf '#!/bin/sh\nexit 0\n' > "$T/bin/logger"
chmod +x "$T/bin/curl" "$T/bin/logger"
now="$(date +%s)"
printf '{ "name": "mysub", "url": "http://example.invalid/sub", "updated": %s, "format": "uri", "skipped": 0, "info": { "title": "T" },\n  "nodes": [ { "name": "NL", "link": "ss://YWVzLTI1Ni1nY206cHc@1.2.3.4:8388#NL" } ] }\n' \
	"$((now - 600))" > "$T/subs/mysub.json"

sub() {
	env PATH="$T/bin:$PATH" MAYHEM_UCI_DIR="$T/uci" MAYHEM_RUN_DIR="$T/run" MAYHEM_SUBS_DIR="$T/subs" MAYHEM_TMP_DIR="$T" \
		"$@" "$UCODE" -L "$FILES/usr/share/ucode/*.uc" "$FILES/usr/share/mayhem/sub.uc" update --no-wait >/dev/null 2>&1
}

# after a reboot: no state
sub
if grep -q '"updated": *'"$((now - 600))" "$T/run/subs-state.json" 2>/dev/null && [ ! -e "$T/curl.log" ]; then
	ok "a fresh cache after a reboot: the state learns it, nothing is downloaded"
else
	bad "a fresh cache after a reboot: state $(cat "$T/run/subs-state.json" 2>/dev/null), curl $(cat "$T/curl.log" 2>/dev/null)"
fi

# The cache is now broken: read again, it would look stale and be downloaded.
cp "$T/subs/mysub.json" "$T/mysub.good"
echo '{ broken' > "$T/subs/mysub.json"
sub
if [ ! -e "$T/curl.log" ] && ! grep -q '"error"' "$T/run/subs-state.json"; then
	ok "the next minute: the cache on flash is not read"
else
	bad "the next minute: the cache was read again: curl $(cat "$T/curl.log" 2>/dev/null), state $(cat "$T/run/subs-state.json")"
fi

if command -v strace >/dev/null 2>&1 && strace -o /dev/null true 2>/dev/null; then
	cp "$T/mysub.good" "$T/subs/mysub.json"
	sub strace -f -e trace=open,openat -o "$T/strace.log"
	if grep -q 'subs/mysub.json' "$T/strace.log"; then
		bad "the cache was opened: $(grep 'subs/mysub.json' "$T/strace.log" | head -n 1)"
	else
		ok "the cache is not opened (strace)"
	fi
fi

rm -rf "$T"
exit "$fail"
