#!/bin/sh
set -eu

ROOT="$(cd "$(dirname "$0")/.." && pwd)"
FILES="$ROOT/mayhem/files"
UCODE="${UCODE:-ucode}"
T="$(mktemp -d)"
fail=0

trap 'rm -rf "$T"' EXIT

ok() { printf 'ok   %s\n' "$1"; }
bad() { printf 'FAIL %s\n' "$1"; fail=1; }

mkdir -p "$T/run"
export MAYHEM_RUN_DIR="$T/run"

# Spawn a short-lived process
sleep 10 &
child_pid=$!

touch "$T/run/applying.$child_pid"

check_applying() {
	python3 - "$T/run" <<'PY'
import os, sys, glob, re, time

run_dir = sys.argv[1]
now = time.time()
applying = False

for f in glob.glob(os.path.join(run_dir, "applying.*")):
    m = re.search(r"applying\.([0-9]+)$", f)
    if m:
        pid = int(m.group(1))
        # Check if process is alive: on Unix os.kill(pid, 0) checks existence
        alive = False
        try:
            os.kill(pid, 0)
            alive = True
        except OSError:
            alive = False
        if not alive:
            try:
                os.unlink(f)
            except OSError:
                pass
            continue
    st = os.stat(f)
    if now - st.st_mtime < 300:
        applying = True
    else:
        try:
            os.unlink(f)
        except OSError:
            pass

print("1" if applying else "0")
PY
}

# 1. While child is running, applying.<pid> is preserved and reports 1
res_alive="$(check_applying)"
if [ "$res_alive" = "1" ] && [ -f "$T/run/applying.$child_pid" ]; then
	ok "applying.<pid> detected while process is running"
else
	bad "applying.<pid> not detected for live process: $res_alive"
fi

# 2. Terminate child process
kill -9 "$child_pid" 2>/dev/null || true
wait "$child_pid" 2>/dev/null || true

# 3. Next check must clean up dead applying.<pid> and return 0
res_dead="$(check_applying)"
if [ "$res_dead" = "0" ] && [ ! -f "$T/run/applying.$child_pid" ]; then
	ok "applying.<pid> automatically removed when process terminates"
else
	bad "applying.<pid> remained after process termination: file exists=$(test -f "$T/run/applying.$child_pid" && echo yes || echo no)"
fi

exit "$fail"
