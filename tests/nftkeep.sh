#!/bin/sh
# New firewall rules while xray works (mayhem_net_up on reload): the
# addresses dnsmasq put into its sets stay in the new table, unless the
# domains of the set changed. Real nft in a network namespace of its own
# (root, unshare); skipped without them.
#   tests/nftkeep.sh

set -u

ROOT="$(cd "$(dirname "$0")/.." && pwd)"
FILES="$ROOT/mayhem/files"

if [ "${NFTKEEP_INNER:-}" != 1 ]; then
	if ! command -v nft >/dev/null 2>&1 || ! unshare -n true 2>/dev/null; then
		echo "skipped: needs nft and unshare -n (root)"
		exit 0
	fi

	exec env NFTKEEP_INNER=1 unshare -n sh "$0"
fi

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

mkdir -p "$T/run" "$T/dnsmasq.d" "$T/bin"
export MAYHEM_RUN_DIR="$T/run" MAYHEM_LIB_DIR="$FILES/usr/share/mayhem" MAYHEM_DNSMASQ_DIRS="$T/dnsmasq.d" MAYHEM_IPV6=1
# no policy routing here: only the nftables part is tested
printf '#!/bin/sh\nexit 0\n' > "$T/bin/ip"
chmod +x "$T/bin/ip"
export PATH="$T/bin:$PATH"

# The table as the generator writes it, $1: one more rule.
conf() {
	cat > "$T/run/nft.conf" <<EOF
table inet mayhem
delete table inet mayhem

table inet mayhem {
	set tun_a_d4 {
		type ipv4_addr
	}
	set tun_a_d6 {
		type ipv6_addr
	}
	set tun_b_d4 {
		type ipv4_addr
	}
	set oth_d4 {
		type ipv4_addr
		flags timeout
		timeout 1h
	}

	chain prerouting {
		type filter hook prerouting priority mangle; policy accept;
		ip daddr @tun_a_d4 counter return
		ip daddr @tun_b_d4 counter return
		$1
	}
}
EOF
}

net_up() { sh -c ". '$MAYHEM_LIB_DIR/lib.sh'; mayhem_net_up" 2>"$T/err" || bad "net_up: $(cat "$T/err")"; }
has() { nft list set inet mayhem "$1" 2>/dev/null | grep -q "$2"; }

conf ''
printf 'nftset=/a.com/4#inet#mayhem#tun_a_d4,6#inet#mayhem#tun_a_d6\nnftset=/b.com/4#inet#mayhem#tun_b_d4,6#inet#mayhem#tun_b_d6\nnftset=/#/4#inet#mayhem#oth_d4,6#inet#mayhem#oth_d6\n' > "$T/run/dnsmasq.conf"
cp "$T/run/dnsmasq.conf" "$T/dnsmasq.d/mayhem.conf"
net_up

# dnsmasq resolved a few names meanwhile
nft add element inet mayhem tun_a_d4 '{ 1.1.1.1, 2.2.2.2 }'
nft add element inet mayhem tun_a_d6 '{ 2001:db8::1 }'
nft add element inet mayhem tun_b_d4 '{ 3.3.3.3 }'
nft add element inet mayhem oth_d4 '{ 4.4.4.4 timeout 10m }'
i=0
while [ "$i" -lt 1200 ]; do
	printf '10.%d.%d.%d' $((i / 65536)) $((i / 256 % 256)) $((i % 256))
	i=$((i + 1))
	[ "$i" -lt 1200 ] && printf ', '
done > "$T/many"
nft add element inet mayhem oth_d4 "{ $(cat "$T/many") }"

# New rules; the domains of section b changed.
conf 'meta l4proto udp counter return'
sed -i 's|/b.com/|/b.com/c.com/|' "$T/run/dnsmasq.conf"
net_up

if nft list chain inet mayhem prerouting | grep -q 'meta l4proto udp'; then ok "the new rules are in"; else bad "new rules: $(nft list ruleset)"; fi
if has tun_a_d4 1.1.1.1 && has tun_a_d4 2.2.2.2 && has tun_a_d6 2001:db8::1; then ok "addresses of unchanged domains stay"; else bad "kept: $(nft list set inet mayhem tun_a_d4)"; fi
if has oth_d4 4.4.4.4 && has oth_d4 10.0.4.175; then ok "a set with timeouts keeps its addresses, many of them"; else bad "oth: $(nft list set inet mayhem oth_d4 | head -c 400)"; fi
if ! has tun_b_d4 3.3.3.3 && grep -qx tun_b_d4 "$T/run/nft.emptied" && ! grep -q tun_a "$T/run/nft.emptied"; then
	ok "a set whose domains changed starts empty"
else
	bad "changed: $(nft list set inet mayhem tun_b_d4) / $(cat "$T/run/nft.emptied")"
fi

# The first start: no table, nothing kept, nothing fails.
nft delete table inet mayhem
net_up
if nft list set inet mayhem tun_a_d4 >/dev/null 2>&1 && ! has tun_a_d4 1.1.1.1; then ok "first start: empty sets"; else bad "first start: $(nft list ruleset)"; fi

rm -rf "$T"
[ "$fail" = 0 ] && echo "nft keep tests passed"
exit "$fail"
