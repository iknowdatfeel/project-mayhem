#!/bin/sh
# Locks of lib.sh (flock): two starts at once next to a lock left behind by
# a process that is gone never run their critical parts together, a live
# owner keeps its lock, background jobs do not inherit it; two folds of the
# connection log at once leave conn.names whole.
#   tests/locks.sh

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

mkdir -p "$T/bin" "$T/run"
printf '#!/bin/sh\nexit 0\n' > "$T/bin/logger"
chmod +x "$T/bin/logger"
export PATH="$T/bin:$PATH" MAYHEM_RUN_DIR="$T/run" MAYHEM_LIB_DIR="$ROOT/mayhem/files/usr/share/mayhem" STUB="$T"

# A lock of a process that is gone, as an older Mayhem left it.
mkdir -p "$T/run/start.lock"
echo 999999 > "$T/run/start.lock/pid"

critical() {
	# shellcheck disable=SC2016 # expanded by the inner shell
	sh -c '. "$MAYHEM_LIB_DIR/lib.sh"
		mayhem_lock start || { echo "$1 refused" >> "$STUB/log"; exit 1; }
		echo "$1 in" >> "$STUB/log"
		sleep 1
		echo "$1 out" >> "$STUB/log"
		mayhem_unlock start' sh "$1"
}

: > "$T/log"
critical a &
a=$!
critical b &
b=$!
wait "$a" "$b"
seq="$(tr '\n' ' ' < "$T/log")"
case "$seq" in
	"a in a out b in b out "|"b in b out a in a out ") ok "two starts next to a dead lock: one after the other" ;;
	*) bad "two starts at once: $seq" ;;
esac

# A live owner keeps its lock: a waiter with a short wait gives up.
# shellcheck disable=SC2016
sh -c '. "$MAYHEM_LIB_DIR/lib.sh"; mayhem_lock start; sleep 3; mayhem_unlock start' &
owner=$!
sleep 0.5
# shellcheck disable=SC2016
if sh -c '. "$MAYHEM_LIB_DIR/lib.sh"; mayhem_lock start 1'; then
	bad "a live owner's lock was taken"
else
	ok "a live owner keeps its lock"
fi
wait "$owner"

# A job started in the background under the lock does not keep it.
# shellcheck disable=SC2016
sh -c '. "$MAYHEM_LIB_DIR/lib.sh"; mayhem_lock start; ( sleep 3 ) 6>&- 7>&- 8>&- 9>&- & mayhem_unlock start' &
sleep 0.5
# shellcheck disable=SC2016
if sh -c '. "$MAYHEM_LIB_DIR/lib.sh"; mayhem_lock start 1 && mayhem_unlock start'; then
	ok "a background job does not keep the lock"
else
	bad "a background job kept the lock"
fi
wait

# Two folds of the connection log at once.
awk 'BEGIN { for (i = 1; i <= 2000; i++) printf "2026/11/16 10:00:00.000 got answer: h%d.example. A -> [10.0.%d.%d] 1ms\n", i, int(i / 250), i % 250 }' > "$T/run/conn.log"
# shellcheck disable=SC2016
sh -c '. "$MAYHEM_LIB_DIR/lib.sh"; mayhem_conn_fold' &
a=$!
# shellcheck disable=SC2016
sh -c '. "$MAYHEM_LIB_DIR/lib.sh"; mayhem_conn_fold' &
b=$!
wait "$a" "$b"
lines="$(wc -l < "$T/run/conn.names")"
good="$(grep -c '^d 10\.0\.[0-9]*\.[0-9]* h[0-9]*\.example$' "$T/run/conn.names")"
left="$(find "$T/run" \( -name '*.new*' -o -name '*.t.*' \) | wc -l | tr -d ' ')"
if [ "$lines" = 2000 ] && [ "$good" = 2000 ] && [ ! -s "$T/run/conn.log" ] && [ "$left" = 0 ]; then
	ok "two folds at once: conn.names whole"
else
	bad "two folds at once: $lines lines, $good good, $left temporary files"
fi

# The lock of update.uc (a directory with the pid of its owner): one without
# a pid yet, just taken, is not taken from its owner; one without a pid for
# more than 10 s was left behind and is.
UCODE="${UCODE:-ucode}"
FILES="$ROOT/mayhem/files"
mkdir -p "$T/uci" && : > "$T/uci/mayhem"
update() {
	MAYHEM_UCI_DIR="$T/uci" MAYHEM_GEO_DIR="$T/geo" MAYHEM_LISTS_DIR="$T/lists" \
		"$UCODE" -L "$FILES/usr/share/ucode/*.uc" "$FILES/usr/share/mayhem/update.uc" geo >/dev/null 2>&1
}
mkdir "$T/run/update.lock"
update
rc=$?
if [ "$rc" = 4 ] && [ -d "$T/run/update.lock" ]; then
	ok "update.uc: a lock just taken (no pid yet) stays with its owner"
else
	bad "update.uc: a fresh lock without a pid: rc $rc, lock $(ls -d "$T/run/update.lock" 2>/dev/null)"
fi
touch -d '-20 sec' "$T/run/update.lock"
update
rc=$?
if [ "$rc" = 0 ] && [ ! -d "$T/run/update.lock" ]; then
	ok "update.uc: a lock without a pid for 20 s is taken over"
else
	bad "update.uc: an old lock without a pid: rc $rc"
fi
# two at once: never both
for i in 1 2 3 4 5 6; do
	( update; echo $? >> "$T/rcs" ) &
done
wait
if [ "$(grep -c '^0$' "$T/rcs")" -ge 1 ] && [ "$(grep -c -v '^[04]$' "$T/rcs")" = 0 ]; then
	ok "update.uc: runs at once wait as busy"
else
	bad "update.uc: runs at once: $(tr '\n' ' ' < "$T/rcs")"
fi

rm -rf "$T"
exit "$fail"
