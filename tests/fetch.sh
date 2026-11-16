#!/bin/sh
# Downloads of the installer and of the command line, with a stand-in for
# curl: the direct download has a connect timeout and a time limit, so a
# hung connection does not hold the installer or the nightly update.
#   tests/fetch.sh

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

mkdir -p "$T/bin"
cat > "$T/bin/curl" <<'EOF'
#!/bin/sh
echo "$*" > "$STUB/curl"
EOF
chmod +x "$T/bin/curl"

sed -n '/^fetch() {/,/^}/p' "$ROOT/install.sh" > "$T/install-fetch.sh"
sed -n '/^fetch() {/,/^}/p' "$ROOT/mayhem/files/usr/bin/mayhem" > "$T/cli-fetch.sh"

for f in install cli; do
	rm -f "$T/curl"
	env -u MAYHEM_PROXY PATH="$T/bin:$PATH" STUB="$T" sh -c "
		mayhem_download_proxy() { :; }
		. '$T/$f-fetch.sh'
		fetch https://example.invalid/x '$T/out'
	" >/dev/null 2>&1
	args=" $(cat "$T/curl" 2>/dev/null) "
	case "$args" in
		*" --connect-timeout 15 "*) has_ct=1 ;;
		*) has_ct=0 ;;
	esac
	case "$args" in
		*" -m 600 "*) has_m=1 ;;
		*) has_m=0 ;;
	esac
	if [ "$has_ct" = 1 ] && [ "$has_m" = 1 ]; then
		ok "$f: the direct download has its time limits"
	else
		bad "$f: curl $args"
	fi
done

rm -rf "$T"
exit "$fail"
