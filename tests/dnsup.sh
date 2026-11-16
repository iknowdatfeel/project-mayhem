#!/bin/sh
# Mayhem's file for dnsmasq goes into its conf-dir only when dnsmasq takes
# it (dnsmasq --test, a stand-in here): a broken one leaves the old file and
# dnsmasq alone, and the error goes to the log and status.json.
#   tests/dnsup.sh

set -u

ROOT="$(cd "$(dirname "$0")/.." && pwd)"
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

mkdir -p "$T/bin" "$T/run" "$T/conf" "$T/dnsmasq"
# dnsmasq: refuses a file with "bad" in it, as dnsmasq --test does.
cat > "$T/bin/dnsmasq" <<'EOF'
#!/bin/sh
for a; do case "$a" in --conf-file=*) f="${a#--conf-file=}" ;; esac; done
if grep -q bad "$f"; then
	echo "dnsmasq: bad option at line 2 of $f" >&2
	exit 1
fi
echo "dnsmasq: syntax check OK."
EOF
cat > "$T/bin/logger" <<'EOF'
#!/bin/sh
echo "$*" >> "$STUB/log"
EOF
cat > "$T/bin/init" <<'EOF'
#!/bin/sh
echo "$1" >> "$STUB/restarts"
EOF
chmod +x "$T/bin/"*
echo 'nameserver 10.9.9.9' > "$T/resolv.conf.auto"

dns_up() {
	# shellcheck disable=SC2016 # expanded by the inner shell
	PATH="$T/bin:$PATH" STUB="$T" MAYHEM_RUN_DIR="$T/run" MAYHEM_LIB_DIR="$ROOT/mayhem/files/usr/share/mayhem" \
		MAYHEM_DNSMASQ_DIRS="$T/conf" MAYHEM_DNSMASQ_INIT="$T/bin/init" MAYHEM_DNSMASQ_BIN="$T/bin/dnsmasq" \
		MAYHEM_DNS_SERVERS="$T/dnsmasq/mayhem.servers" MAYHEM_RESOLV_AUTO="$T/resolv.conf.auto" \
		sh -c '. "$MAYHEM_LIB_DIR/lib.sh"; mayhem_dns_up' >/dev/null 2>&1
}

printf 'no-resolv\nserver=/old.example/1.1.1.1\n' > "$T/conf/mayhem.conf"
printf 'no-resolv\nbad line\n' > "$T/run/dnsmasq.conf"
echo '{ "ok": true, "errors": [ ] }' > "$T/run/status.json"
dns_up
if grep -q 'old.example' "$T/conf/mayhem.conf" && [ ! -s "$T/restarts" ] && grep -q 'daemon.err' "$T/log" 2>/dev/null &&
   grep -q 'dnsmasq does not take the new file: dnsmasq: bad option' "$T/run/status.json"; then
	ok "a file dnsmasq refuses: the old one stays, no restart, the error shown"
else
	bad "refused file: conf $(cat "$T/conf/mayhem.conf"), restarts $(cat "$T/restarts" 2>/dev/null), status $(cat "$T/run/status.json")"
fi

printf 'no-resolv\nserver=/new.example/1.1.1.1\n' > "$T/run/dnsmasq.conf"
dns_up
if grep -q 'new.example' "$T/conf/mayhem.conf" && [ "$(cat "$T/restarts" 2>/dev/null)" = restart ]; then
	ok "a file dnsmasq takes goes in, dnsmasq restarted"
else
	bad "good file: conf $(cat "$T/conf/mayhem.conf"), restarts $(cat "$T/restarts" 2>/dev/null)"
fi

rm -rf "$T"
exit "$fail"
