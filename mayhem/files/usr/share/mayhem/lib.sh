# Mayhem: helpers for the service, the xray wrapper and the CLI.
# shellcheck shell=ash

. "${MAYHEM_LIB_DIR:-/usr/share/mayhem}/const.sh"

mayhem_log() {
	# $1 message, $2 level (info|notice|warn|err)
	logger -t mayhem -p "daemon.${2:-info}" -- "$1"
}

# --- policy routing + nftables -----------------------------------------------

mayhem_net_up() {
	local run="$MAYHEM_RUN_DIR"
	local mark="$MAYHEM_FWMARK/$MAYHEM_FWMARK"

	local v6="${MAYHEM_IPV6:-0}"

	ip rule del fwmark "$mark" table "$MAYHEM_RT_TABLE" 2>/dev/null
	ip rule add fwmark "$mark" table "$MAYHEM_RT_TABLE" priority "$MAYHEM_RULE_PRIO" || return 1
	ip route replace local 0.0.0.0/0 dev lo table "$MAYHEM_RT_TABLE" || return 1

	if [ "$v6" = 1 ]; then
		ip -6 rule del fwmark "$mark" table "$MAYHEM_RT_TABLE" 2>/dev/null

		if ! ip -6 rule add fwmark "$mark" table "$MAYHEM_RT_TABLE" priority "$MAYHEM_RULE_PRIO" ||
		   ! ip -6 route replace local ::/0 dev lo table "$MAYHEM_RT_TABLE"; then
			mayhem_log "IPv6 interception is not available, IPv6 traffic goes direct" warn
			v6=0
		fi
	fi

	# Without IPv6 policy routing the IPv6 TPROXY rule would blackhole traffic.
	if [ "$v6" = 1 ]; then
		nft -f "$run/nft.conf"
	else
		sed '/meta nfproto ipv6/d' "$run/nft.conf" | nft -f -
	fi
}

mayhem_net_down() {
	local mark="$MAYHEM_FWMARK/$MAYHEM_FWMARK"
	local i

	nft delete table inet "$MAYHEM_NFT_TABLE" 2>/dev/null

	for i in 1 2 3; do
		ip rule del fwmark "$mark" table "$MAYHEM_RT_TABLE" 2>/dev/null || break
	done
	ip route flush table "$MAYHEM_RT_TABLE" 2>/dev/null

	for i in 1 2 3; do
		ip -6 rule del fwmark "$mark" table "$MAYHEM_RT_TABLE" 2>/dev/null || break
	done
	ip -6 route flush table "$MAYHEM_RT_TABLE" 2>/dev/null

	return 0
}

# --- dnsmasq -----------------------------------------------------------------
# The redirect lives only in dnsmasq's conf-dir under /tmp: nothing is written
# to flash, and a reboot or a crash cleanup always returns plain DNS.

mayhem_dnsmasq_dirs() {
	local dirs

	dirs="$(sed -n 's/^conf-dir=\([^,]*\).*/\1/p' /var/etc/dnsmasq.conf.* 2>/dev/null | sort -u)"
	[ -n "$dirs" ] || dirs="/tmp/dnsmasq.d"
	echo "$dirs"
}

mayhem_dns_up() {
	local d

	for d in $(mayhem_dnsmasq_dirs); do
		mkdir -p "$d" && cp "$MAYHEM_RUN_DIR/dnsmasq.conf" "$d/$MAYHEM_DNSMASQ_FILE"
	done

	"$MAYHEM_DNSMASQ_INIT" restart >/dev/null 2>&1
}

mayhem_dns_down() {
	local d changed=0

	for d in $(mayhem_dnsmasq_dirs) /tmp/dnsmasq.d; do
		if [ -f "$d/$MAYHEM_DNSMASQ_FILE" ]; then
			rm -f "$d/$MAYHEM_DNSMASQ_FILE"
			changed=1
		fi
	done

	[ "$changed" = 1 ] && "$MAYHEM_DNSMASQ_INIT" restart >/dev/null 2>&1

	return 0
}

# --- state -------------------------------------------------------------------

# Is something listening on TCP port $1 (any address family)?
mayhem_port_listening() {
	local hex f

	hex="$(printf '%04X' "$1")"

	# tcp6 is missing on kernels without IPv6; awk would fail on it.
	for f in /proc/net/tcp /proc/net/tcp6; do
		[ -r "$f" ] || continue
		awk -v p=":$hex" 'toupper($2) ~ (p "$") && $4 == "0A" { f = 1 } END { exit !f }' "$f" && return 0
	done

	return 1
}

# Prints the names of running services that also intercept traffic.
mayhem_conflicts() {
	local s found=""

	for s in $MAYHEM_CONFLICTS; do
		[ -x "/etc/init.d/$s" ] || continue
		/etc/init.d/"$s" running >/dev/null 2>&1 && found="$found $s"
	done

	# Any other TPROXY ruleset (unknown clients) is a conflict as well.
	if nft list ruleset 2>/dev/null | awk -v t="$MAYHEM_NFT_TABLE" '
		/^table / { cur = $3 }
		/tproxy/ && cur != t { f = 1 }
		END { exit !f }'; then
		found="$found other-tproxy"
	fi

	echo "${found# }"
}

mayhem_xray_version() {
	[ -x "$MAYHEM_XRAY_BIN" ] || return 1
	"$MAYHEM_XRAY_BIN" version 2>/dev/null | awk 'NR == 1 { print $2 }'
}
