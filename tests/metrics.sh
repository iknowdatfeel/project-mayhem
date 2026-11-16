#!/bin/sh
# xray's metrics endpoint (mayhem.metrics) against a fake one on 127.0.0.1:12781:
# an endpoint that takes the connection and never answers (a stopped or hung
# xray) costs the deadline, not forever; an answer in chunks (Go's way for
# HTTP/1.1) and a plain one are both read.
#   UCODE=ucode tests/metrics.sh      (needs ucode's socket module and python3)

set -u

ROOT="$(cd "$(dirname "$0")/.." && pwd)"
UCODE="${UCODE:-ucode}"
T="$(mktemp -d)"
fail=0
FAKE=""

cleanup() {
	[ -n "$FAKE" ] && kill "$FAKE" 2>/dev/null
	rm -rf "$T"
}
trap cleanup EXIT

ok() { printf 'ok   %s\n' "$1"; }
bad() { printf 'FAIL %s\n' "$1"; fail=1; }

if ! "$UCODE" -e 'import * as s from "socket";' 2>/dev/null; then
	echo "skip: ucode has no socket module"
	exit 0
fi

cat > "$T/fake.py" <<'PY'
import socket, sys, time
mode = sys.argv[1]
body = b'{"observatory":{"n-a":{"alive":true,"delay":42}},"pad":"' + b'x' * 5000 + b'"}'
s = socket.socket()
s.setsockopt(socket.SOL_SOCKET, socket.SO_REUSEADDR, 1)
s.bind(('127.0.0.1', 12781))
s.listen(8)
print('ready', flush=True)
while True:
    c, _ = s.accept()
    req = c.recv(4096)
    if mode == 'hang':
        time.sleep(30)
    elif mode == 'chunked':
        out = b'HTTP/1.1 200 OK\r\nContent-Type: application/json\r\nTransfer-Encoding: chunked\r\n\r\n'
        for i in range(0, len(body), 1000):
            part = body[i:i + 1000]
            out += b'%x\r\n' % len(part) + part + b'\r\n'
        c.sendall(out + b'0\r\n\r\n')
    else:
        c.sendall(b'HTTP/1.0 200 OK\r\nContent-Type: application/json\r\n\r\n' + body)
    c.close()
PY

start_fake() {
	[ -n "$FAKE" ] && kill "$FAKE" 2>/dev/null && wait "$FAKE" 2>/dev/null
	python3 "$T/fake.py" "$1" > "$T/fake.out" 2>&1 &
	FAKE=$!
	i=0
	while [ "$i" -lt 50 ] && ! grep -q ready "$T/fake.out" 2>/dev/null; do
		sleep 0.1
		i=$((i + 1))
	done
}

read_vars() {
	"$UCODE" -L "$ROOT/mayhem/files/usr/share/ucode/*.uc" -e '
		import * as m from "mayhem.metrics";
		const t = clock(true);
		const o = m.observatory(1500);
		const u = clock(true);
		print(sprintf("%d %J\n", (u[0] - t[0]) * 1000 + (u[1] - t[1]) / 1000000, o));
	' 2>&1
}

start_fake hang
out="$(read_vars)"
ms="${out%% *}"
case "$out" in
	*"{ }"*|*"{}"*)
		if [ "$ms" -lt 3000 ]; then
			ok "metrics: a hung endpoint costs the deadline (${ms} ms), not forever"
		else
			bad "metrics: a hung endpoint took ${ms} ms"
		fi
		;;
	*) bad "metrics: a hung endpoint gave $out" ;;
esac

start_fake chunked
out="$(read_vars)"
case "$out" in
	*'"delay": 42'*) ok "metrics: an answer in chunks is read" ;;
	*) bad "metrics: an answer in chunks gave $out" ;;
esac

start_fake plain
out="$(read_vars)"
case "$out" in
	*'"delay": 42'*) ok "metrics: a plain HTTP/1.0 answer is read" ;;
	*) bad "metrics: a plain answer gave $out" ;;
esac

exit "$fail"
