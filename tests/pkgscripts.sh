#!/bin/sh
# The package's prerm and postrm from mayhem/Makefile with stand-ins: an
# update through opkg (PKG_UPGRADE=1) neither disables the service nor
# removes anything; a removal does both, as before.
#   tests/pkgscripts.sh

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

mkdir -p "$T/bin" "$T/init.d" "$T/sysctl.d"
# shellcheck disable=SC2016 # $1 and $* of the stand-ins
for s in mayhem mayhem-hold; do
	printf '#!/bin/sh\necho "%s $1" >> "%s/calls"\n' "$s" "$T" > "$T/init.d/$s"
done
# shellcheck disable=SC2016
printf '#!/bin/sh\necho "rm $*" >> "%s/calls"\n' "$T" > "$T/bin/rm"
# shellcheck disable=SC2016
printf '#!/bin/sh\necho "sysctl $*" >> "%s/calls"\n' "$T" > "$T/bin/sysctl"
chmod +x "$T/init.d/"* "$T/bin/"*

# The script of a define block, as the package gets it ($$ -> $), with the
# stand-ins' paths.
script() {
	sed -n "/^define Package\/mayhem\/$1\$/,/^endef\$/p" "$ROOT/mayhem/Makefile" | sed '1d;$d' |
		sed -e 's/\$\$/$/g' -e "s|/etc/init.d/|$T/init.d/|g" -e "s|/etc/sysctl.d/|$T/sysctl.d/|g" > "$T/$1"
}
script prerm
script postrm

run() {
	# $1 script, $2 PKG_UPGRADE ('' for none), $3 the argument
	: > "$T/calls"
	: > "$T/sysctl.d/12-mayhem-bbr.conf"
	if [ -n "$2" ]; then
		PATH="$T/bin:$PATH" PKG_UPGRADE="$2" sh "$T/$1" "$3" >/dev/null 2>&1
	else
		env -u PKG_UPGRADE PATH="$T/bin:$PATH" sh "$T/$1" "$3" >/dev/null 2>&1
	fi
}

run prerm 1 upgrade
if [ ! -s "$T/calls" ]; then
	ok "prerm on an update: the service is not disabled"
else
	bad "prerm on an update: $(tr '\n' '|' < "$T/calls")"
fi

run postrm 1 upgrade
if [ ! -s "$T/calls" ]; then
	ok "postrm on an update: nothing removed"
else
	bad "postrm on an update: $(tr '\n' '|' < "$T/calls")"
fi

run prerm '' remove
if grep -q '^mayhem disable$' "$T/calls" && grep -q '^mayhem-hold disable$' "$T/calls"; then
	ok "prerm on removal: the service is disabled"
else
	bad "prerm on removal: $(tr '\n' '|' < "$T/calls")"
fi

run postrm '' remove
if grep -q '^rm -f /usr/libexec/mayhem/xray$' "$T/calls" && grep -q '^rm -rf /var/run/mayhem$' "$T/calls" &&
   grep -q "^rm -f $T/sysctl.d/12-mayhem-bbr.conf\$" "$T/calls"; then
	ok "postrm on removal: xray, the run directory and BBR go"
else
	bad "postrm on removal: $(tr '\n' '|' < "$T/calls")"
fi

/bin/rm -rf "$T"
exit "$fail"
