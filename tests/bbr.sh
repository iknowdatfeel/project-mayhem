#!/bin/sh
# mayhem bbr with stand-ins for the package manager, modprobe and sysctl: the
# module is installed when missing, the setting is kept in sysctl.d, a
# firmware without the module changes nothing, and --no-install (the package
# scripts) only switches it on when the module is there.
#   tests/bbr.sh

set -u

ROOT="$(cd "$(dirname "$0")/.." && pwd)"
FILES="$ROOT/mayhem/files"
T="$(mktemp -d)"
fail=0

ok() { printf 'ok   %s\n' "$1"; }
bad() { printf 'FAIL %s\n' "$1"; fail=1; }

mkdir -p "$T/bin" "$T/run"
sed "s|/usr/share/mayhem/lib.sh|$FILES/usr/share/mayhem/lib.sh|" "$FILES/usr/bin/mayhem" > "$T/mayhem"

# apk: installs kmod-tcp-bbr unless $STUB/no_pkg exists; modprobe: loads it
# when installed; sysctl: records the call.
cat > "$T/bin/apk" <<'S'
#!/bin/sh
echo "apk $*" >> "$STUB/pm.log"
case "$1" in
	info) [ -f "$STUB/installed" ] ;;
	add) [ -f "$STUB/no_pkg" ] && exit 1; : > "$STUB/installed" ;;
	*) exit 0 ;;
esac
S
cat > "$T/bin/modprobe" <<'S'
#!/bin/sh
[ -f "$STUB/installed" ] && echo 'reno cubic bbr' > "$STUB/avail"
S
printf '#!/bin/sh\nexit 1\n' > "$T/bin/insmod"
# shellcheck disable=SC2016
printf '#!/bin/sh\necho "$*" >> "$STUB/sysctl.log"\n' > "$T/bin/sysctl"
chmod +x "$T/bin/"* "$T/mayhem"

run() {
	STUB="$T" PATH="$T/bin:$PATH" MAYHEM_LIB_DIR="$FILES/usr/share/mayhem" MAYHEM_RUN_DIR="$T/run" MAYHEM_BBR_AVAIL="$T/avail" MAYHEM_BBR_SYSCTL="$T/sysctl.d/12-mayhem-bbr.conf" \
		sh "$T/mayhem" bbr "$@" >/dev/null 2>&1
}

reset() { rm -rf "$T/sysctl.d" "$T/installed" "$T/no_pkg" "$T/pm.log" "$T/sysctl.log"; echo 'reno cubic' > "$T/avail"; }

# The module is not installed yet: it is, and BBR goes on and stays.
reset
if run && grep -q 'apk add kmod-tcp-bbr' "$T/pm.log" && grep -q 'tcp_congestion_control=bbr' "$T/sysctl.d/12-mayhem-bbr.conf" &&
   grep -q 'net.ipv4.tcp_congestion_control=bbr' "$T/sysctl.log"; then
	ok "bbr: the module is installed and TCP switched"
else
	bad "bbr install: $(cat "$T/pm.log" "$T/sysctl.log" 2>/dev/null)"
fi

# Already there (an update): nothing to install.
: > "$T/pm.log"
if run && ! grep -q 'apk add' "$T/pm.log"; then
	ok "bbr: an update installs nothing again"
else
	bad "bbr again: $(cat "$T/pm.log")"
fi

# The package scripts: no package manager, only the switch.
reset
if ! run --no-install && [ ! -s "$T/pm.log" ] && [ ! -f "$T/sysctl.d/12-mayhem-bbr.conf" ]; then
	ok "bbr --no-install: without the module nothing is installed or changed"
else
	bad "bbr --no-install: $(cat "$T/pm.log" 2>/dev/null)"
fi

# A firmware without the module in its feeds.
reset
: > "$T/no_pkg"
if ! run && [ ! -f "$T/sysctl.d/12-mayhem-bbr.conf" ] && [ ! -s "$T/sysctl.log" ]; then
	ok "bbr: without the module TCP stays as it was"
else
	bad "bbr without the module: $(cat "$T/sysctl.log" 2>/dev/null)"
fi

rm -rf "$T"
[ "$fail" = 0 ] && echo "bbr tests passed"
exit "$fail"
