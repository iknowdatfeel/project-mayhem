#!/bin/sh
# The provider's DNS servers: at boot Mayhem waits for them (the WAN comes up
# after its turn), and a configuration built without them (a boot that
# waited in vain, a reload while the internet was down) gets them from the
# scheduler when they are there again - once a build, at most once in 5 min.
#   tests/ispdns.sh

set -u

ROOT="$(cd "$(dirname "$0")/.." && pwd)"
T="$(mktemp -d)"
trap 'rm -rf "$T"' EXIT
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
cat > "$T/bin/logger" <<'EOF'
#!/bin/sh
echo "$*" >> "$STUB/log"
EOF
cat > "$T/bin/init" <<'EOF'
#!/bin/sh
echo "$1" >> "$STUB/reloads"
EOF
# uci: mayhem.settings.enabled and mayhem.dns.domestic from files.
cat > "$T/bin/uci" <<'EOF'
#!/bin/sh
for a; do k="$a"; done
case "$k" in
	mayhem.settings.enabled) cat "$STUB/enabled" 2>/dev/null ;;
	mayhem.dns.domestic) cat "$STUB/domestic" 2>/dev/null ;;
esac
EOF
chmod +x "$T/bin/"*

lib() {
	# shellcheck disable=SC2016 # expanded by the inner shell
	PATH="$T/bin:$PATH" STUB="$T" MAYHEM_RUN_DIR="$T/run" MAYHEM_LIB_DIR="$ROOT/mayhem/files/usr/share/mayhem" \
		MAYHEM_INIT="$T/bin/init" MAYHEM_RESOLV_AUTO="$T/resolv.a $T/resolv.b" \
		sh -c '. "$MAYHEM_LIB_DIR/lib.sh"; "$@"' _ "$@"
}

# --- the list, as the generator takes it -------------------------------------

printf '# Interface wan\nnameserver 127.0.0.1\nnameserver ::1\nnameserver fe80::1%%wan\nnameserver 91.234.165.183\nnameserver bad.name\n' > "$T/resolv.a"
got="$(lib mayhem_isp_dns_list | tr '\n' ' ')"
if [ "$got" = "fe80::1 91.234.165.183 " ]; then
	ok "the provider's servers: no loopback, no names, no scope"
else
	bad "the provider's servers: got '$got'"
fi

: > "$T/resolv.a"
echo 'nameserver 10.9.9.9' > "$T/resolv.b"
if [ "$(lib mayhem_isp_dns_list)" = "10.9.9.9" ]; then
	ok "the second file when the first has none"
else
	bad "the second file: got '$(lib mayhem_isp_dns_list)'"
fi

# --- waiting at boot -----------------------------------------------------------

: > "$T/resolv.b"
echo 1 > "$T/enabled"
if lib mayhem_isp_dns_pending; then
	ok "boot without the provider's servers: wait"
else
	bad "boot without the provider's servers does not wait"
fi

echo '1.1.1.1' > "$T/domestic"
if lib mayhem_isp_dns_pending; then
	bad "boot with a domestic DNS of the user's own waits"
else
	ok "a domestic DNS of the user's own: no wait"
fi
rm -f "$T/domestic"

echo 0 > "$T/enabled"
if lib mayhem_isp_dns_pending; then
	bad "Mayhem turned off waits at boot"
else
	ok "Mayhem turned off: no wait"
fi
echo 1 > "$T/enabled"

# The WAN comes up during the wait (the internet was down and is back).
( sleep 2; echo 'nameserver 91.234.165.183' > "$T/resolv.a" ) &
start="$(date +%s)"
if lib mayhem_isp_dns_wait 10 && [ $(($(date +%s) - start)) -lt 8 ]; then
	ok "the wait ends when the servers come"
else
	bad "the wait did not end when the servers came"
fi
wait

: > "$T/resolv.a"
start="$(date +%s)"
if lib mayhem_isp_dns_wait 2; then
	bad "the wait without servers says they came"
elif [ $(($(date +%s) - start)) -gt 5 ]; then
	bad "the wait without servers does not stop at its limit"
else
	ok "no servers: the wait stops at its limit"
fi

# --- the scheduler applies them when they come later ---------------------------

status() {
	# $1 generated, $2 fallback (true|false)
	printf '{\n\t"ok": true,\n\t"generated": %s,\n\t"isp_dns_fallback": %s\n}\n' "$1" "$2" > "$T/run/status.json"
}
reloads() { wc -l < "$T/reloads" 2>/dev/null | tr -d ' ' || echo 0; }

: > "$T/run/active"
status 1000 true
lib mayhem_isp_dns_catchup
if [ ! -s "$T/reloads" ]; then
	ok "no servers yet: no reload"
else
	bad "a reload without the provider's servers"
fi

echo 'nameserver 91.234.165.183' > "$T/resolv.a"
lib mayhem_isp_dns_catchup
lib mayhem_isp_dns_catchup
if [ "$(reloads)" = 1 ] && grep -q "provider's DNS servers are there now" "$T/log"; then
	ok "the servers came: one reload for the build"
else
	bad "the servers came: $(reloads) reloads"
fi

# The reload built without them again (the internet down once more): not in
# the same 5 minutes - no loop.
status 1001 true
lib mayhem_isp_dns_catchup
if [ "$(reloads)" = 1 ]; then
	ok "a new build without them: no second reload within 5 minutes"
else
	bad "a second reload within 5 minutes: $(reloads)"
fi

# After that: one more.
echo "1000 $(($(date +%s) - 400))" > "$T/run/isp-dns.retry"
lib mayhem_isp_dns_catchup
if [ "$(reloads)" = 2 ]; then
	ok "a new build without them later: one more reload"
else
	bad "no reload for a later build: $(reloads)"
fi

# A build with the provider's servers, or Mayhem not working: nothing.
rm -f "$T/run/isp-dns.retry"
status 1002 false
lib mayhem_isp_dns_catchup
status 1003 true
rm -f "$T/run/active"
lib mayhem_isp_dns_catchup
if [ "$(reloads)" = 2 ]; then
	ok "a build with them, or Mayhem not working: no reload"
else
	bad "a reload with the provider's servers or Mayhem not working: $(reloads)"
fi

# --- an interface comes up ------------------------------------------------------

# A reload only when it changed what the build used: the generator keeps
# runtime.fp, ifacefp.uc compares (real ucode, the config of the tests).
UCODE="${UCODE:-ucode}"
printf '#!/bin/sh\nexec %s -L "%s/mayhem/files/usr/share/ucode/*.uc" "$@"\n' "$UCODE" "$ROOT" > "$T/bin/ucode"
chmod +x "$T/bin/ucode"
mkdir -p "$T/uci"
cp "$ROOT/tests/uci/mayhem" "$T/uci/"
export MAYHEM_UCI_DIR="$T/uci" MAYHEM_GEO_DIR="$T/geo" MAYHEM_LISTS_DIR="$T/lists" MAYHEM_SUBS_DIR="$T/subs" MAYHEM_TMP_DIR="$T"
echo 'nameserver 10.1.1.1' > "$T/resolv.a"
PATH="$T/bin:$PATH" MAYHEM_RUN_DIR="$T/run" MAYHEM_RESOLV_AUTO="$T/resolv.a $T/resolv.b" \
	ucode "$ROOT/mayhem/files/usr/share/mayhem/gen.uc" --out "$T/run" >/dev/null 2>&1
: > "$T/reloads"
lib mayhem_iface_reload
if [ -s "$T/run/runtime.fp" ] && [ "$(reloads)" = 0 ]; then
	ok "an interface up that changes nothing: no reload"
else
	bad "an interface up that changes nothing: $(reloads) reloads, fp $(cat "$T/run/runtime.fp" 2>/dev/null)"
fi
echo 'nameserver 10.2.2.2' > "$T/resolv.a"
lib mayhem_iface_reload
if [ "$(reloads)" = 1 ]; then
	ok "new provider DNS servers with an interface up: a reload"
else
	bad "new provider DNS servers with an interface up: $(reloads) reloads"
fi
rm -f "$T/run/runtime.fp"
lib mayhem_iface_reload
if [ "$(reloads)" = 2 ]; then
	ok "no fingerprint of the last build: a reload"
else
	bad "no fingerprint: $(reloads) reloads"
fi

exit "$fail"
