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

get_inode() {
	if stat -c %i "$1" 2>/dev/null; then
		return
	fi
	stat -f %i "$1" 2>/dev/null
}

mkdir -p "$T/run" "$T/bin"
export MAYHEM_RUN_DIR="$T/run" MAYHEM_LIB_DIR="$FILES/usr/share/mayhem"
printf 'key1\n' > "$T/run/xray.key"
printf 'key1\n' > "$T/run/running.xray.key"
printf '{"outbounds": []}\n' > "$T/run/xray.json"
printf '{"outbounds": []}\n' > "$T/run/running.xray.json"
printf 'bal tag1\n' > "$T/run/overrides"
printf 'bal tag1\n' > "$T/run/running.overrides"

# 1. Test mayhem_mark_restart from lib.sh
sh -c '. "$MAYHEM_LIB_DIR/lib.sh"; mayhem_mark_restart "manual"'

ino_key="$(get_inode "$T/run/xray.key")"
ino_run_key="$(get_inode "$T/run/running.xray.key")"

if [ -n "$ino_key" ] && [ -n "$ino_run_key" ] && [ "$ino_key" != "$ino_run_key" ]; then
	ok "xray.key and running.xray.key have different inodes after restart mark"
else
	bad "xray.key and running.xray.key shared inode: $ino_key == $ino_run_key"
fi

# 2. Test atomic file copying without hard links
if command -v "$UCODE" >/dev/null 2>&1; then
	"$UCODE" -e '
		import * as fs from "fs";
		const run = getenv("MAYHEM_RUN_DIR");
		for (let f in ["xray.json", "overrides"]) {
			const tmp = `${run}/running.${f}.tmp`;
			fs.unlink(tmp);
			if (fs.writefile(tmp, fs.readfile(`${run}/${f}`)) != null)
				fs.rename(tmp, `${run}/running.${f}`);
		}
	'
else
	for f in xray.json overrides; do
		cp -f "$MAYHEM_RUN_DIR/$f" "$MAYHEM_RUN_DIR/running.$f.tmp"
		mv -f "$MAYHEM_RUN_DIR/running.$f.tmp" "$MAYHEM_RUN_DIR/running.$f"
	done
fi

ino_json="$(get_inode "$T/run/xray.json")"
ino_run_json="$(get_inode "$T/run/running.xray.json")"
ino_ov="$(get_inode "$T/run/overrides")"
ino_run_ov="$(get_inode "$T/run/running.overrides")"

if [ "$ino_json" != "$ino_run_json" ] && [ "$ino_ov" != "$ino_run_ov" ]; then
	ok "working and running files never share inodes (no hard links)"
else
	bad "inodes shared: json ($ino_json vs $ino_run_json), ov ($ino_ov vs $ino_run_ov)"
fi

exit "$fail"
