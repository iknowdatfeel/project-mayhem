#!/bin/sh
# The obfuscator service (mayhem-obfs) with fake procd and UCI: an instance per
# obfuscated tunnel, wg-obfuscator with its key in a config file only, phantun
# with a TUN device of its own. Prints what went wrong.
#   tests/obfs-svc.sh

set -u

ROOT="$(cd "$(dirname "$0")/.." && pwd)"
T="$(mktemp -d)"
trap 'rm -rf "$T"' EXIT
mkdir -p "$T/bin" "$T/run"
printf '#!/bin/sh\nexit 0\n' > "$T/bin/wg-obfuscator"
cp "$T/bin/wg-obfuscator" "$T/bin/phantun_client"
chmod +x "$T/bin/wg-obfuscator" "$T/bin/phantun_client"

out="$(MAYHEM_OBFS_DIR="$T/bin" MAYHEM_RUN_DIR="$T/run" sh -c '
	config_load() { :; }
	config_foreach() { $1 ob_a; $1 ob_b; $1 ob_c; $1 ob_d; }
	logger() { :; }
	config_get() {
		case "$2.$3" in
		ob_a.iface) eval $1=awg0 ;; ob_a.kind) eval $1=phobos ;; ob_a.key) eval $1=s3cret ;; ob_a.lport) eval $1=41820 ;;
		ob_b.iface) eval $1=wg1 ;; ob_b.kind) eval $1=faketcp ;; ob_b.lport) eval $1=41821 ;;
		ob_c.iface) eval $1=wg2 ;; ob_c.kind) eval $1=nonsense ;; ob_c.lport) eval $1=41822 ;;
		ob_d.iface) eval $1=wg3 ;; ob_d.kind) eval $1=phobos ;; ob_d.key) eval $1=k ;; ob_d.lport) eval $1=41823 ;; ob_d.host) eval $1=127.0.0.1 ;;
		*.host) eval $1=203.0.113.10 ;; *.port) eval $1=4567 ;; ob_a.masking) eval $1=STUN ;;
		*) eval $1=\"\${4:-}\" ;;
		esac
	}
	procd_open_instance() { echo "instance $1"; }
	procd_set_param() { echo "param $*"; }
	procd_close_instance() { :; }
	. "$1"
	start_service
' sh "$ROOT/mayhem/files/etc/init.d/mayhem-obfs" 2>&1)"

fail=0
need() { printf '%s\n' "$out" | grep -qF -- "$1" || { echo "missing: $1"; fail=1; }; }

need "instance awg0"
need "param command $T/bin/wg-obfuscator -c $T/run/obfs-awg0.conf"
need "instance wg1"
need "param command $T/bin/phantun_client --local 127.0.0.1:41821 --remote 203.0.113.10:4567 --tun mhft0 --tun-local 10.255.0.1 --tun-peer 10.255.0.2 --ipv4-only"
grep -q '^key = s3cret$' "$T/run/obfs-awg0.conf" 2>/dev/null || { echo "no key in the config file"; fail=1; }
grep -q '^masking = STUN$' "$T/run/obfs-awg0.conf" 2>/dev/null || { echo "no masking in the config file"; fail=1; }
grep -q '^target = 203.0.113.10:4567$' "$T/run/obfs-awg0.conf" 2>/dev/null || { echo "no target in the config file"; fail=1; }
# wg-obfuscator 1.6 refuses to start with any other verbosity (WARNINGS was
# written before, and the obfuscator never ran).
grep -Eq '^verbose = (ERROR|WARN|INFO|DEBUG|TRACE)$' "$T/run/obfs-awg0.conf" 2>/dev/null || { echo "verbosity wg-obfuscator does not accept: $(grep verbose "$T/run/obfs-awg0.conf")"; fail=1; }
grep -q '^resolve-interval = ' "$T/run/obfs-awg0.conf" 2>/dev/null || { echo "no resolve-interval: a name not resolvable on boot stops the obfuscator"; fail=1; }
printf '%s\n' "$out" | grep -q s3cret && { echo "the key is on the command line"; fail=1; }
printf '%s\n' "$out" | grep -q 'instance wg2' && { echo "an unknown obfuscator got an instance"; fail=1; }
printf '%s\n' "$out" | grep -q 'instance wg3' && { echo "an obfuscator sending to 127.0.0.1 got an instance"; fail=1; }

[ "$fail" = 0 ] || printf '%s\n' "$out"
exit "$fail"
