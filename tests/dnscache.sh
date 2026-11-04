#!/bin/sh
# Native policy keeps dnsmasq's listener unchanged. Route and policy changes
# must still invalidate cached replies; unchanged routes must retain the cache.
set -eu
ROOT="$(cd "$(dirname "$0")/.." && pwd)"
T="$(mktemp -d)"
trap 'rm -rf "$T"' EXIT
export MAYHEM_LIB_DIR="$ROOT/mayhem/files/usr/share/mayhem" MAYHEM_RUN_DIR="$T/run" \
	MAYHEM_DNS_SERVERS="$T/servers" MAYHEM_DNSMASQ_DIRS="$T/conf" MAYHEM_DNSMASQ_INIT="$T/init" CACHE_LOG="$T/events"
mkdir -p "$MAYHEM_RUN_DIR" "$MAYHEM_DNSMASQ_DIRS"
. "$MAYHEM_LIB_DIR/lib.sh"
ISP=10.0.0.1
mayhem_isp_dns() { echo "server=$ISP"; }
mayhem_dnsmasq_hup() { echo flush >> "$CACHE_LOG"; }
cat > "$MAYHEM_DNSMASQ_INIT" <<'EOF'
#!/bin/sh
echo "$1" >> "$CACHE_LOG"
EOF
chmod +x "$MAYHEM_DNSMASQ_INIT"
expect_events() {
	got="$(cat "$CACHE_LOG")"
	[ "$got" = "$2" ] || { printf 'FAIL %s: expected [%s], got [%s]\n' "$1" "$2" "$got"; exit 1; }
	printf 'ok   %s\n' "$1"
	: > "$CACHE_LOG"
}
mayhem_dns_servers isp
: > "$CACHE_LOG"
cp "$MAYHEM_DNS_SERVERS" "$T/listener.before"
mayhem_dns_servers isp
expect_events 'unchanged ISP route keeps DNS cache' ''
echo 'server=127.0.0.1#12753' > "$MAYHEM_RUN_DIR/dns.xray"
mayhem_dns_servers xray
expect_events 'ISP to Xray flushes DNS cache behind the same listener' flush
cmp -s "$T/listener.before" "$MAYHEM_DNS_SERVERS"
mayhem_dns_servers xray
expect_events 'unchanged Xray route keeps DNS cache' ''
ISP=10.0.0.2
mayhem_dns_servers xray
expect_events 'new ISP for native Direct flushes DNS cache' flush
mayhem_dns_servers isp
expect_events 'Xray to ISP flushes DNS cache behind the same listener' flush
cmp -s "$T/listener.before" "$MAYHEM_DNS_SERVERS"
: > "$MAYHEM_RUN_DIR/active"
printf 'no-resolv\nservers-file=%s\n' "$MAYHEM_DNS_SERVERS" > "$MAYHEM_RUN_DIR/dnsmasq.conf"
mayhem_dns_up
expect_events 'first include installation restarts dnsmasq' restart
mayhem_dns_up
expect_events 'policy reload with unchanged include flushes DNS cache' flush
printf 'no-resolv\nservers-file=%s\nserver=/changed.test/10.0.0.2\n' "$MAYHEM_DNS_SERVERS" > "$MAYHEM_RUN_DIR/dnsmasq.conf.new"
mv "$MAYHEM_RUN_DIR/dnsmasq.conf.new" "$MAYHEM_RUN_DIR/dnsmasq.conf"
mayhem_dns_up
expect_events 'changed include restarts dnsmasq' restart
