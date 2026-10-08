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

	mayhem_tunnels_down

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

# --- tunnel sections ---------------------------------------------------------
# $MAYHEM_RUN_DIR/tunnels: "section device mark table v6" per line. In kernel
# mode, marked packets use the section's routing table, which holds a default
# route into the device only while the tunnel works: otherwise the lookup
# falls through to the main table and the traffic goes direct. The xray path
# of every tunnel section is a balancer that is pointed at "direct" meanwhile.

mayhem_tunnels_up() {
	local name dev mark table v6

	[ -s "$MAYHEM_RUN_DIR/tunnels" ] || return 0

	while read -r name dev mark table v6; do
		[ "$mark" = - ] && continue
		ip rule add fwmark "$mark/$MAYHEM_TUN_MASK" table "$table" priority "$MAYHEM_TUN_RULE_PRIO"
		[ "$v6" = 1 ] && ip -6 rule add fwmark "$mark/$MAYHEM_TUN_MASK" table "$table" priority "$MAYHEM_TUN_RULE_PRIO"
	done < "$MAYHEM_RUN_DIR/tunnels"

	rm -f "$MAYHEM_RUN_DIR"/tunnel.*
	mayhem_tunnels_check force
	return 0
}

mayhem_tunnels_down() {
	local i=0

	while ip rule del priority "$MAYHEM_TUN_RULE_PRIO" 2>/dev/null && [ "$i" -lt 64 ]; do i=$((i + 1)); done
	i=0
	while ip -6 rule del priority "$MAYHEM_TUN_RULE_PRIO" 2>/dev/null && [ "$i" -lt 64 ]; do i=$((i + 1)); done

	i=1
	while [ "$i" -le 32 ]; do
		ip route flush table $((110 + i)) 2>/dev/null
		ip -6 route flush table $((110 + i)) 2>/dev/null
		i=$((i + 1))
	done

	rm -f "$MAYHEM_RUN_DIR"/tunnel.*
	return 0
}

# Seconds since the newest WireGuard/AmneziaWG handshake of device $1; empty
# for other kinds of devices (they count as working while the link is up).
mayhem_handshake_age() {
	local out now newest

	out="$(awg show "$1" latest-handshakes 2>/dev/null)" || out="$(wg show "$1" latest-handshakes 2>/dev/null)" || return 0
	newest="$(printf '%s\n' "$out" | awk '$2 > m { m = $2 } END { print m + 0 }')"
	now="$(date +%s)"

	if [ "$newest" -gt 0 ]; then
		echo $((now - newest))
	else
		echo 999999
	fi
}

mayhem_tunnel_ok() {
	local dev="$1" age

	[ -d "/sys/class/net/$dev" ] || return 1
	[ "$(cat "/sys/class/net/$dev/operstate" 2>/dev/null)" = down ] && return 1

	age="$(mayhem_handshake_age "$dev")"
	[ -z "$age" ] && return 0
	[ "$age" -le 180 ] && return 0

	# An idle tunnel does not handshake: send something through it and look again.
	ping -c 1 -W 2 -I "$dev" 1.1.1.1 >/dev/null 2>&1
	sleep 3
	age="$(mayhem_handshake_age "$dev")"
	[ -n "$age" ] && [ "$age" -le 180 ]
}

# Brings each tunnel section's routes and xray balancer in line with the
# state of its tunnel. Runs every minute from the scheduler.
mayhem_tunnels_check() {
	local name dev mark table v6 state was xpid

	[ -s "$MAYHEM_RUN_DIR/tunnels" ] || return 0
	[ -f "$MAYHEM_RUN_DIR/active" ] || [ "$1" = force ] || [ -f "$MAYHEM_RUN_DIR/xray.pid" ] || return 0

	while read -r name dev mark table v6; do
		was="$(cat "$MAYHEM_RUN_DIR/tunnel.$name" 2>/dev/null)"

		if mayhem_tunnel_ok "$dev"; then
			state=up

			if [ "$table" != - ]; then
				ip route replace default dev "$dev" table "$table" 2>/dev/null
				[ "$v6" = 1 ] && ip -6 route replace default dev "$dev" table "$table" 2>/dev/null
			fi

			if [ "$was" != up ]; then
				mayhem_select "bal-$name" ""
				[ -n "$was" ] && mayhem_log "tunnel $dev of section $name works again"
			fi
		else
			state=down

			if [ "$table" != - ]; then
				ip route flush table "$table" 2>/dev/null
				ip -6 route flush table "$table" 2>/dev/null
			fi

			# Again only when xray is another process now: every call is
			# one more xray (`xray api`, ~30 MB for a moment).
			xpid="$(cat "$MAYHEM_RUN_DIR/xray.pid" 2>/dev/null)"

			if [ "$was" != down ] || [ "$(cat "$MAYHEM_RUN_DIR/tunnel.$name.sel" 2>/dev/null)" != "$xpid" ]; then
				mayhem_select "bal-$name" direct && echo "$xpid" > "$MAYHEM_RUN_DIR/tunnel.$name.sel"
			fi

			[ "$was" != down ] && mayhem_log "tunnel $dev of section $name does not work, its traffic goes direct" warn
		fi

		echo "$state" > "$MAYHEM_RUN_DIR/tunnel.$name"
	done < "$MAYHEM_RUN_DIR/tunnels"
}

# --- watchdog ------------------------------------------------------------------
# Runs every minute from the scheduler. xray restarts when its memory stays
# above a share of the RAM for 3 checks in a row; dnsmasq is restarted when
# it is gone, and Mayhem's DNS settings are dropped if it will not start with
# them (the router keeps working DNS either way).

mayhem_watchdog_note() {
	echo "$(date +%s) $1" >> "$MAYHEM_RUN_DIR/watchdog.log"
	tail -n 20 "$MAYHEM_RUN_DIR/watchdog.log" > "$MAYHEM_RUN_DIR/watchdog.log.tmp" &&
		mv "$MAYHEM_RUN_DIR/watchdog.log.tmp" "$MAYHEM_RUN_DIR/watchdog.log"
}

# The helper proxy of the main section when downloads go through Xray (the
# "Download through Xray" switch); empty otherwise. Callers fall back to a
# direct download when it does not work, e.g. while xray is stopped.
mayhem_download_proxy() {
	local sec

	[ "$(uci -q get mayhem.geo.via_xray)" = 0 ] && return 0
	[ -z "$(uci -q get mayhem.geo.via_xray)" ] && [ "$(uci -q get mayhem.geo.update_via)" = direct ] && return 0

	sec="$(grep -o '"default_section": *"[A-Za-z0-9_]*"' "$MAYHEM_RUN_DIR/nodes.json" 2>/dev/null | head -n 1 | sed 's/.*"\([A-Za-z0-9_]*\)"$/\1/')"
	[ -n "$sec" ] && echo "socks5h://sec-$sec:mayhem@127.0.0.1:$MAYHEM_HELPER_PORT"
}

# Once a day, half an hour into the nightly update hour: Mayhem's own update
# when it is turned on. It runs apart from the scheduler, in a session of its
# own: the installer stops and starts the service.
mayhem_auto_update() {
	local hour day stamp="$MAYHEM_RUN_DIR/auto-update.day"

	[ "$(uci -q get mayhem.settings.auto_update)" = 1 ] || return 0
	hour="$(uci -q get mayhem.geo.update_hour)"
	[ "$(date +%H)" -eq "${hour:-4}" ] 2>/dev/null && [ "$(date +%M)" -ge 30 ] || return 0

	day="$(date +%Y%m%d)"
	[ "$(cat "$stamp" 2>/dev/null)" = "$day" ] && return 0
	echo "$day" > "$stamp"

	[ -e "$MAYHEM_RUN_DIR/install.pid" ] && return 0

	if command -v setsid >/dev/null 2>&1; then
		setsid /usr/bin/mayhem auto-update >"$MAYHEM_RUN_DIR/auto-update.log" 2>&1 </dev/null &
	else
		( /usr/bin/mayhem auto-update >"$MAYHEM_RUN_DIR/auto-update.log" 2>&1 </dev/null & )
	fi
}

mayhem_watchdog() {
	local pid rss total pct limit n

	[ "${MAYHEM_WATCHDOG:-$(uci -q get mayhem.settings.watchdog)}" = 0 ] && return 0

	pid="$(cat "$MAYHEM_RUN_DIR/xray.pid" 2>/dev/null)"

	if [ -n "$pid" ] && [ -d "/proc/$pid" ]; then
		rss="$(awk '/^VmRSS:/ { print $2 }' "/proc/$pid/status" 2>/dev/null)"
		total="$(awk '/^MemTotal:/ { print $2 }' /proc/meminfo)"
		pct="${MAYHEM_WATCHDOG_MEM:-$(uci -q get mayhem.settings.watchdog_mem)}"
		limit=$(( ${total:-0} * ${pct:-40} / 100 ))

		if [ "${rss:-0}" -gt "$limit" ]; then
			n=$(( $(cat "$MAYHEM_RUN_DIR/watchdog.mem" 2>/dev/null || echo 0) + 1 ))

			if [ "$n" -ge 3 ]; then
				mayhem_log "xray has used ${rss} KiB for 3 minutes (limit ${limit} KiB), restarting it" warn
				mayhem_watchdog_note "xray restarted: ${rss} KiB of memory"
				n=0
				kill -TERM "$pid"
			fi

			echo "$n" > "$MAYHEM_RUN_DIR/watchdog.mem"
		else
			echo 0 > "$MAYHEM_RUN_DIR/watchdog.mem"
		fi
	fi

	# Only when dnsmasq is the router's DNS (not replaced by something else).
	[ -f "$MAYHEM_RUN_DIR/active" ] || return 0
	"$MAYHEM_DNSMASQ_INIT" enabled >/dev/null 2>&1 || return 0
	pidof dnsmasq >/dev/null 2>&1 && { rm -f "$MAYHEM_RUN_DIR/watchdog.dns"; return 0; }

	n=$(( $(cat "$MAYHEM_RUN_DIR/watchdog.dns" 2>/dev/null || echo 0) + 1 ))
	echo "$n" > "$MAYHEM_RUN_DIR/watchdog.dns"

	if [ "$n" -le 2 ]; then
		mayhem_log "dnsmasq is not running, restarting it" warn
		mayhem_watchdog_note "dnsmasq restarted"
		"$MAYHEM_DNSMASQ_INIT" restart >/dev/null 2>&1
	elif [ "$n" = 3 ]; then
		mayhem_log "dnsmasq does not start with Mayhem's DNS settings, removing them until Mayhem restarts" err
		mayhem_watchdog_note "dnsmasq does not start with Mayhem's settings: they were removed"
		mayhem_dns_down
		"$MAYHEM_DNSMASQ_INIT" restart >/dev/null 2>&1
	fi
}

# --- dnsmasq -----------------------------------------------------------------
# The redirect lives only in dnsmasq's conf-dir under /tmp: nothing is written
# to flash, and a reboot or a crash cleanup always returns plain DNS.

mayhem_dnsmasq_dirs() {
	local dirs

	if [ -n "$MAYHEM_DNSMASQ_DIRS" ]; then
		echo "$MAYHEM_DNSMASQ_DIRS"
		return
	fi

	dirs="$(sed -n 's/^conf-dir=\([^,]*\).*/\1/p' /var/etc/dnsmasq.conf.* 2>/dev/null | sort -u)"
	[ -n "$dirs" ] || dirs="/tmp/dnsmasq.d"
	echo "$dirs"
}

mayhem_dns_up() {
	local d

	# A hard link when the conf-dir is on the same tmpfs: with tunnel sections
	# the file holds every domain of their lists and would take RAM twice.
	for d in $(mayhem_dnsmasq_dirs); do
		mkdir -p "$d" || continue
		rm -f "$d/$MAYHEM_DNSMASQ_FILE"
		ln "$MAYHEM_RUN_DIR/dnsmasq.conf" "$d/$MAYHEM_DNSMASQ_FILE" 2>/dev/null ||
			cp "$MAYHEM_RUN_DIR/dnsmasq.conf" "$d/$MAYHEM_DNSMASQ_FILE"
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

# Balancer choices saved by the user: "<balancer> <outbound tag>" per line.
mayhem_apply_overrides() {
	local bal tag

	[ -s "$MAYHEM_RUN_DIR/overrides" ] || return 0

	while read -r bal tag; do
		if [ -z "$bal" ] || [ -z "$tag" ]; then
			continue
		fi

		mayhem_select "$bal" "$tag" ||
			mayhem_log "could not select $tag in $bal" warn
	done < "$MAYHEM_RUN_DIR/overrides"
}

# A reload with new servers and nothing else changed: swap them in running
# xray (live.uc). Connections keep going through the servers they use. When
# that fails, the restart key changes and procd restarts xray.
mayhem_live_update() {
	[ -f "$MAYHEM_RUN_DIR/active" ] || return 0

	ucode "$MAYHEM_LIB_DIR/live.uc" && return 0

	mayhem_log "could not change the servers in running xray, restarting it" warn
	echo "restart $(date +%s)" >> "$MAYHEM_RUN_DIR/xray.key"
}

# Pin a balancer to a server; an empty tag returns it to automatic choice.
mayhem_select() {
	if [ -n "$2" ]; then
		"$MAYHEM_XRAY_BIN" api bo --server="127.0.0.1:$MAYHEM_API_PORT" -b "$1" "$2" >/dev/null 2>&1
	else
		"$MAYHEM_XRAY_BIN" api bo --server="127.0.0.1:$MAYHEM_API_PORT" -b "$1" -r >/dev/null 2>&1
	fi
}
