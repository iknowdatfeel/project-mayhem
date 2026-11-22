#!/bin/sh
# mayhem_ports_listening of lib.sh on files in place of /proc/net/tcp and
# tcp6: every port must listen (state 0A), in either file; one missing, or
# only connected, is not enough. With busybox awk too when it is there.
#   tests/ports.sh

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

mkdir -p "$T/net" "$T/bb"
# 12345 (3039) and 53 (0035) listen over IPv4, 10085 (2765) over IPv6;
# 8080 (1F90) is only a connection.
cat > "$T/net/tcp" <<'TCP'
  sl  local_address rem_address   st tx_queue rx_queue tr tm->when retrnsmt   uid  timeout inode
   0: 0100007F:3039 00000000:0000 0A 00000000:00000000 00:00000000 00000000     0        0 1 1 0 100 0 0 10 0
   1: 00000000:0035 00000000:0000 0A 00000000:00000000 00:00000000 00000000     0        0 2 1 0 100 0 0 10 0
   2: 0100007F:1F90 0100007F:D431 01 00000000:00000000 00:00000000 00000000     0        0 3 1 0 100 0 0 10 0
TCP
cat > "$T/net/tcp6" <<'TCP'
  sl  local_address                         remote_address                        st tx_queue rx_queue tr tm->when retrnsmt   uid  timeout inode
   0: 00000000000000000000000001000000:2765 00000000000000000000000000000000:0000 0A 00000000:00000000 00:00000000 00000000     0        0 4 1 0 100 0 0 10 0
TCP

check() {
	# $1 what, $2 0 or 1 expected, the rest: ports
	local what="$1" want="$2" got
	shift 2
	# shellcheck disable=SC2016 # expanded by the inner shell
	sh -c '. "$1/mayhem/files/usr/share/mayhem/lib.sh"; shift; mayhem_ports_listening "$@"' sh "$ROOT" "$@"
	got=$?
	if [ "$got" = "$want" ]; then ok "$label$what"; else bad "$label$what: $got"; fi
}

run_all() {
	check "all three listen, over IPv4 and IPv6" 0 12345 53 10085
	check "one port" 0 53
	check "a port that does not listen" 1 12345 53 9999
	check "a connection is not a listener" 1 8080
	check "the same port twice" 0 53 53
	MAYHEM_PROC_NET="$T/none" check "no files" 1 53
	rm -f "$T/v6"
	mv "$T/net/tcp6" "$T/v6"
	check "no tcp6 (a kernel without IPv6)" 0 12345 53
	mv "$T/v6" "$T/net/tcp6"
}

export MAYHEM_PROC_NET="$T/net" MAYHEM_LIB_DIR="$ROOT/mayhem/files/usr/share/mayhem"
label=""
run_all
if command -v busybox >/dev/null 2>&1; then
	ln -s "$(command -v busybox)" "$T/bb/awk"
	PATH="$T/bb:$PATH" label="busybox awk: " run_all
fi

rm -rf "$T"
exit "$fail"
