#!/bin/sh
# An idle tunnel is woken by a ping to an address its AllowedIPs take, with
# stand-ins for wg and ping: 10.8.0.0/24 -> an address of that subnet,
# 0.0.0.0/0 -> 1.1.1.1, ::/0 alone -> IPv6.
#   tests/wake.sh

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
# wg: a handshake an hour ago, AllowedIPs from $STUB/allowed.
cat > "$T/bin/wg" <<'EOF'
#!/bin/sh
case "$3" in
	latest-handshakes) printf 'PEERKEY=\t%s\n' "$(( $(date +%s) - 3600 ))" ;;
	allowed-ips) printf 'PEERKEY=\t%s\n' "$(cat "$STUB/allowed")" ;;
esac
EOF
printf '#!/bin/sh\nexit 1\n' > "$T/bin/awg"
# shellcheck disable=SC2016
printf '#!/bin/sh\necho "$*" > "$STUB/ping"\nexit 0\n' > "$T/bin/ping"
chmod +x "$T/bin/"*

wake() {
	# $1 AllowedIPs -> the arguments of ping (the device: lo, which exists)
	printf '%s' "$1" > "$T/allowed"
	rm -f "$T/ping"
	# shellcheck disable=SC2016 # expanded by the inner shell
	PATH="$T/bin:$PATH" STUB="$T" MAYHEM_LIB_DIR="$ROOT/mayhem/files/usr/share/mayhem" \
		sh -c '. "$MAYHEM_LIB_DIR/lib.sh"; mayhem_tunnel_ok lo' >/dev/null 2>&1
	cat "$T/ping" 2>/dev/null
}

got="$(wake '10.8.0.0/24')"
case "$got" in
	"-4 -c 1 -W 2 -I lo 10.8.0."*) ok "AllowedIPs 10.8.0.0/24: ping into that subnet" ;;
	*) bad "AllowedIPs 10.8.0.0/24: ping $got" ;;
esac

got="$(wake '10.8.0.0/24 0.0.0.0/0')"
if [ "$got" = "-4 -c 1 -W 2 -I lo 1.1.1.1" ]; then ok "AllowedIPs 0.0.0.0/0: ping 1.1.1.1"; else bad "AllowedIPs 0.0.0.0/0: ping $got"; fi

got="$(wake '::/0')"
if [ "$got" = "-6 -c 1 -W 2 -I lo 2606:4700:4700::1111" ]; then ok "AllowedIPs ::/0 alone: ping over IPv6"; else bad "AllowedIPs ::/0: ping $got"; fi

got="$(wake 'fd00:8::/64')"
if [ "$got" = "-6 -c 1 -W 2 -I lo fd00:8::" ]; then ok "AllowedIPs of one IPv6 subnet: ping into it"; else bad "AllowedIPs fd00:8::/64: ping $got"; fi

rm -rf "$T"
exit "$fail"
