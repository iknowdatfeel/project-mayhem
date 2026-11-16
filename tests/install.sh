#!/bin/sh
# The installer and "mayhem xray-install" with stand-ins: a failed update
# gives back the autostart and starts the service as it was; xray-install
# leaves the installed xray alone when the flash has no room for the new one.
#   tests/install.sh

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

mkdir -p "$T/bin" "$T/rc.d"

# The service: running, enabled when $T/rc.d has its link; every command noted.
cat > "$T/bin/init" <<'EOF'
#!/bin/sh
echo "$1" >> "$STUB/init.log"
[ "$1" = running ] && exit 0
exit 0
EOF
# The command line: xray-install fails.
cat > "$T/bin/cli" <<'EOF'
#!/bin/sh
echo "$1" >> "$STUB/cli.log"
[ "$1" = xray-install ] && exit 1
exit 0
EOF
chmod +x "$T/bin/init" "$T/bin/cli"

# The installer without its last line (main "$@"), the steps before xray
# stand-ins.
sed '$d' "$ROOT/install.sh" > "$T/installer.sh"

update() {
	# $1: autostart before the update (1/0)
	rm -f "$T/rc.d/"* "$T/init.log" "$T/cli.log"
	[ "$1" = 1 ] && : > "$T/rc.d/S99mayhem"
	STUB="$T" MAYHEM_INIT="$T/bin/init" MAYHEM_CLI="$T/bin/cli" MAYHEM_RC_D="$T/rc.d" sh -c "
		. '$T/installer.sh'
		TMP='$T/tmp'
		msg() { :; }
		warn() { :; }
		check_system() { :; }
		pkg_update() { :; }
		check_deps() { :; }
		download_release() { :; }
		install_packages() { echo prerm >> '$T/init.log'; }
		check_tproxy() { :; }
		main
	" >/dev/null 2>&1
}

update 1
rc=$?
log="$(tr '\n' ' ' < "$T/init.log" 2>/dev/null)"
if [ "$rc" != 0 ] && [ "$log" = "running prerm enable start " ] && grep -q '^xray-install$' "$T/cli.log"; then
	ok "installer: a failed xray-install gives back the autostart and the running service"
else
	bad "installer: rc $rc, service: $log"
fi

update 0
log="$(tr '\n' ' ' < "$T/init.log" 2>/dev/null)"
if [ "$log" = "running prerm start " ]; then
	ok "installer: without autostart before, it stays off after a failure"
else
	bad "installer, no autostart: $log"
fi

# xray-install: the archive's xray takes more than the flash has.
mkdir -p "$T/x/lib" "$T/x/bin"
sed -n '/^cmd_xray_install() {/,/^}/p' "$FILES/usr/bin/mayhem" > "$T/x/lib/xi.sh"
printf 'old xray\n' > "$T/x/lib/xray"
chmod +x "$T/x/lib/xray"
python3 -I -c '
import sys, zipfile
with zipfile.ZipFile(sys.argv[1], "w") as z:
    z.writestr("xray", b"\0" * (3 * 1048576))
' "$T/x/xray.zip"
sum="$(sha256sum "$T/x/xray.zip" | cut -d ' ' -f 1)"
# df: 2 MB free in the directory of xray.
cat > "$T/x/bin/df" <<'EOF'
#!/bin/sh
echo "Filesystem 1K-blocks Used Available Use% Mounted on"
echo "overlay 100000 97952 2048 98% /overlay"
EOF
chmod +x "$T/x/bin/df"
out="$(PATH="$T/x/bin:$PATH" MAYHEM_XRAY_BIN="$T/x/lib/xray" MAYHEM_XRAY_VERSION=26.10.31 sh -c "
	. '$T/x/lib/xi.sh'
	xray_asset() { echo 'linux-64 xray'; }
	mayhem_xray_version() { echo old; }
	fetch() {
		case \"\$1\" in
			*.dgst) echo 'SHA2-256= $sum' > \"\$2\" ;;
			*) cp '$T/x/xray.zip' \"\$2\" ;;
		esac
	}
	cmd_xray_install
" 2>&1)"
rc=$?
if [ "$rc" != 0 ] && [ "$(cat "$T/x/lib/xray")" = "old xray" ] && [ ! -e "$T/x/lib/xray.new" ] &&
   printf '%s' "$out" | grep -q 'Not enough flash space: need 4 MB, have 2 MB'; then
	ok "xray-install: no room on the flash, the installed xray stays"
else
	bad "xray-install without room: rc $rc: $out"
fi

rm -rf "$T"
exit "$fail"
