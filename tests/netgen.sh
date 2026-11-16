#!/bin/sh
# A server chosen by hand without a restart (mayhem_net_generation): the path
# generation of nodes.json goes into the running rules, so connections of the
# old one are reset; the sets keep what dnsmasq put in them; the files follow
# the kernel. The rules are the generator's own (tests/models/global.json), in
# a network namespace of its own (root, unshare); skipped without them.
#   UCODE=ucode tests/netgen.sh

set -u

ROOT="$(cd "$(dirname "$0")/.." && pwd)"
FILES="$ROOT/mayhem/files"
UCODE="${UCODE:-ucode}"

if [ "${NETGEN_INNER:-}" != 1 ]; then
	if ! command -v nft >/dev/null 2>&1 || ! unshare -n true 2>/dev/null; then
		echo "skipped: needs nft and unshare -n (root)"
		exit 0
	fi

	exec env NETGEN_INNER=1 UCODE="$UCODE" unshare -n sh "$0"
fi

T="$(mktemp -d)"
trap 'rm -rf "$T"' EXIT
fail=0

ok() { printf 'ok   %s\n' "$1"; }
bad() {
	printf 'FAIL %s\n' "$1"
	fail=1
	if [ -n "${GITHUB_ACTIONS:-}" ]; then
		printf '::error title=%s::%s\n' "$(basename "$0")" "$1"
	fi
}

mkdir -p "$T/run" "$T/bin" "$T/gen"
export MAYHEM_RUN_DIR="$T/run" MAYHEM_LIB_DIR="$FILES/usr/share/mayhem"
# no policy routing here: IPv6 counts as not intercepted
printf '#!/bin/sh\nexit 1\n' > "$T/bin/ip"
chmod +x "$T/bin/ip"
export PATH="$T/bin:$PATH"

if ! "$UCODE" -L "$FILES/usr/share/ucode/*.uc" "$FILES/usr/share/mayhem/gen.uc" --model "$ROOT/tests/models/global.json" --out "$T/gen" >/dev/null 2>&1; then
	bad "netgen: the generator failed"
	exit 1
fi

sed '/meta nfproto ipv6/d' "$T/gen/nft.conf" > "$T/run/nft.conf"
cp "$T/run/nft.conf" "$T/run/running.nft.conf"
sed 's/"generation": *[0-9]*/"generation": 1/' "$T/gen/nodes.json" > "$T/run/nodes.json"

if ! nft -f "$T/run/running.nft.conf" 2>"$T/err"; then
	bad "netgen: the generator's rules do not load: $(cat "$T/err")"
	exit 1
fi

nft add element inet mayhem oth_d4 '{ 203.0.113.7 }' 2>/dev/null
before="$(nft list set inet mayhem oth_d4 2>/dev/null | grep -c 203.0.113.7)"

# Not running: nothing is touched.
. "$FILES/usr/share/mayhem/lib.sh"

if mayhem_net_generation; then
	bad "netgen: changed the rules while Mayhem is not active"
else
	ok "netgen: nothing while Mayhem is not active"
fi

: > "$T/run/active"
sed -i 's/"generation": *[0-9]*/"generation": 2/' "$T/run/nodes.json"

if mayhem_net_generation; then
	ok "netgen: the new generation is swapped in"
else
	bad "netgen: the new generation was not swapped in"
fi

chain="$(nft list chain inet mayhem prerouting 2>&1)"

case "$chain" in
	*"!= 0x20000000"*) ok "netgen: the kernel resets connections of other generations" ;;
	*) bad "netgen: the kernel's chain has no generation 2: $chain" ;;
esac

case "$chain" in
	*"!= 0x10000000"*) bad "netgen: generation 1 is still in the kernel" ;;
	*) ok "netgen: generation 1 is gone from the kernel" ;;
esac

if [ "$before" = 1 ] && nft list set inet mayhem oth_d4 2>/dev/null | grep -q 203.0.113.7; then
	ok "netgen: the sets keep what dnsmasq put in them"
else
	bad "netgen: an address of a set was lost (before: $before)"
fi

if grep -q '!= 0x20000000' "$T/run/running.nft.conf" && cmp -s "$T/run/running.nft.conf" "$T/run/nft.conf"; then
	ok "netgen: running.nft.conf follows the kernel and nft.conf stays the same as it"
else
	bad "netgen: the files do not follow the kernel"
fi

n="$(nft list table inet mayhem 2>/dev/null | grep -c 'chain prerouting {')"

if [ "$n" = 1 ]; then
	ok "netgen: one chain prerouting"
else
	bad "netgen: the chain prerouting is there $n times"
fi

if mayhem_net_generation && [ -z "$(find "$T/run" -name 'nft.gen.*')" ]; then
	ok "netgen: the same generation again does nothing and leaves no files"
else
	bad "netgen: the same generation again failed or left files"
fi

exit "$fail"
