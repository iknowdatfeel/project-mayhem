#!/bin/sh
# The service stops with stand-ins for nft and ip: with the kill switch on, a
# restart or an update through opkg (PKG_UPGRADE=1) keeps the interception and
# dnsmasq's servers; a plain stop, or the kill switch off, removes them.
#   tests/ksrestart.sh

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

mkdir -p "$T/bin" "$T/run" "$T/dnsmasq"
cat > "$T/bin/nft" <<'EOF'
#!/bin/sh
echo "nft $*" >> "$STUB/calls"
exit 0
EOF
cat > "$T/bin/ip" <<'EOF'
#!/bin/sh
echo "ip $*" >> "$STUB/calls"
exit 1
EOF
for c in logger pidof uci; do printf '#!/bin/sh\nexit 0\n' > "$T/bin/$c"; done
chmod +x "$T/bin/"*
echo 'nameserver 10.9.9.9' > "$T/resolv.conf.auto"

stop() {
	# $1 kill switch (1/0); the rest: environment of the stop
	local ks="$1"
	shift
	: > "$T/calls"
	echo "MAYHEM_KILLSWITCH=$ks" > "$T/run/env"
	echo 'server=127.0.0.1#12753' > "$T/dnsmasq/mayhem.servers"
	env "$@" PATH="$T/bin:$PATH" STUB="$T" MAYHEM_RUN_DIR="$T/run" MAYHEM_LIB_DIR="$FILES/usr/share/mayhem" \
		MAYHEM_DNS_SERVERS="$T/dnsmasq/mayhem.servers" MAYHEM_RESOLV_AUTO="$T/resolv.conf.auto" \
		MAYHEM_DNSMASQ_INIT=/bin/true MAYHEM_KS="$ks" MAYHEM_KS_HOLD=0 \
		sh -c '. "$MAYHEM_LIB_DIR/lib.sh"; mayhem_service_stop' >/dev/null 2>&1
}
kept() { ! grep -q 'delete table inet mayhem' "$T/calls" && [ "$(cat "$T/dnsmasq/mayhem.servers")" = 'server=127.0.0.1#12753' ]; }

stop 1 MAYHEM_RESTART=1
if kept; then ok "kill switch, restart: interception and dnsmasq's servers stay"; else bad "kill switch, restart: $(tr '\n' '|' < "$T/calls")"; fi

stop 1 PKG_UPGRADE=1
if kept; then ok "kill switch, update: interception and dnsmasq's servers stay"; else bad "kill switch, update: $(tr '\n' '|' < "$T/calls")"; fi

stop 1 X=1
if ! kept; then ok "kill switch, plain stop: interception removed"; else bad "kill switch, plain stop kept the interception"; fi

stop 0 MAYHEM_RESTART=1
if grep -q 'delete table inet mayhem' "$T/calls" && [ "$(cat "$T/dnsmasq/mayhem.servers")" = 'server=10.9.9.9' ]; then
	ok "no kill switch, restart: interception removed, the provider's DNS"
else
	bad "no kill switch, restart: $(tr '\n' '|' < "$T/calls") / $(cat "$T/dnsmasq/mayhem.servers")"
fi

rm -rf "$T"
exit "$fail"
