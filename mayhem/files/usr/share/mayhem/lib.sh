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

	# Applied again on reload while traffic flows: rules that are in place
	# stay, the ruleset is swapped in one nft transaction.
	mayhem_ip_rule_has 4 || ip rule add fwmark "$mark" table "$MAYHEM_RT_TABLE" priority "$MAYHEM_RULE_PRIO" || return 1
	ip route replace local 0.0.0.0/0 dev lo table "$MAYHEM_RT_TABLE" || return 1

	if [ "$v6" = 1 ]; then
		if ! { mayhem_ip_rule_has 6 || ip -6 rule add fwmark "$mark" table "$MAYHEM_RT_TABLE" priority "$MAYHEM_RULE_PRIO"; } ||
		   ! ip -6 route replace local ::/0 dev lo table "$MAYHEM_RT_TABLE"; then
			mayhem_log "IPv6 interception is not available, IPv6 traffic goes direct" warn
			v6=0
		fi
	fi

	# Without IPv6 policy routing the IPv6 TPROXY rule would blackhole traffic.
	# The addresses dnsmasq put into the sets go into the new table in the
	# same transaction.
	{
		cat "$run/nft.conf"
		mayhem_nft_kept
	} > "$run/nft.apply"

	if [ "$v6" = 1 ]; then
		nft -f "$run/nft.apply"
	else
		sed '/meta nfproto ipv6/d' "$run/nft.apply" | nft -f -
	fi
}

# The sets dnsmasq fills as it resolves (tun_<section>_d4, px_d6, oth_d4...):
# a new table starts with them empty, and devices that still have the
# addresses (their own DNS cache, a browser's) went the wrong way until they
# asked again - direct instead of through a tunnel. Prints the "add element"
# lines that put back what the running table has, for every such set whose
# domains did not change (the nftset= lines of dnsmasq's file in use and of
# the new one); a set whose domains changed starts empty, or a domain taken
# out of a tunnel would still go into it. The names of the sets that start
# empty go to nft.emptied.
mayhem_nft_kept() {
	local new="$MAYHEM_RUN_DIR/dnsmasq.conf" old="" d set

	: > "$MAYHEM_RUN_DIR/nft.emptied"
	nft list table inet "$MAYHEM_NFT_TABLE" >/dev/null 2>&1 || return 0

	for d in $(mayhem_dnsmasq_dirs); do
		[ -f "$d/$MAYHEM_DNSMASQ_FILE" ] && { old="$d/$MAYHEM_DNSMASQ_FILE"; break; }
	done

	sed -n 's/^\tset \([A-Za-z0-9_]*_d[46]\) {$/\1/p' "$MAYHEM_RUN_DIR/nft.conf" > "$MAYHEM_RUN_DIR/nft.dynsets"

	while read -r set; do
		if [ -z "$old" ] || [ "$(grep -F "#$MAYHEM_NFT_TABLE#$set" "$old" | md5sum)" != "$(grep -F "#$MAYHEM_NFT_TABLE#$set" "$new" 2>/dev/null | md5sum)" ]; then
			echo "$set" >> "$MAYHEM_RUN_DIR/nft.emptied"
			continue
		fi

		# "elements = { a, b expires 5m,\n c }": the addresses, 500 a line.
		nft list set inet "$MAYHEM_NFT_TABLE" "$set" 2>/dev/null | awk -v t="$MAYHEM_NFT_TABLE" -v s="$set" '
			/elements = \{/ { on = 1; sub(/.*elements = \{/, "") }
			on {
				end = sub(/\}.*/, "")
				n = split($0, e, ",")
				for (i = 1; i <= n; i++) {
					split(e[i], w, " ")
					if (w[1] != "")
						a[++k] = w[1]
				}
				if (end)
					on = 0
			}
			END {
				for (i = 1; i <= k; i += 500) {
					line = ""
					for (j = i; j <= k && j < i + 500; j++)
						line = line (j > i ? ", " : "") a[j]
					printf "add element inet %s %s { %s }\n", t, s, line
				}
			}'
	done < "$MAYHEM_RUN_DIR/nft.dynsets"
}

# Is the fwmark rule of IPv$1 in place?
mayhem_ip_rule_has() {
	ip -"$1" rule show 2>/dev/null | grep -qE "fwmark $MAYHEM_FWMARK(/$MAYHEM_FWMARK)? lookup $MAYHEM_RT_TABLE( |\$)"
}

# Reload while xray works: new firewall rules and tunnel routes go in place
# without restarting xray (a new section, a tunnel chosen as the main server).
mayhem_net_refresh() {
	[ -f "$MAYHEM_RUN_DIR/active" ] || return 0

	if ! cmp -s "$MAYHEM_RUN_DIR/nft.conf" "$MAYHEM_RUN_DIR/running.nft.conf"; then
		if mayhem_net_up; then
			cp "$MAYHEM_RUN_DIR/nft.conf" "$MAYHEM_RUN_DIR/running.nft.conf"
			mayhem_log "firewall rules changed without a restart"
			# A set that starts empty (its domains changed) is filled by
			# dnsmasq as it resolves; it does that for upstream answers only,
			# not for what it has cached: drop its cache so the set fills.
			[ -s "$MAYHEM_RUN_DIR/nft.emptied" ] && grep -q 'nftset=' "$MAYHEM_RUN_DIR/dnsmasq.conf" 2>/dev/null && mayhem_dnsmasq_hup
		else
			mayhem_log "could not change the firewall rules, restarting xray" warn
			echo "restart $(date +%s)" >> "$MAYHEM_RUN_DIR/xray.key"
			return 1
		fi
	fi

	if ! cmp -s "$MAYHEM_RUN_DIR/tunnels" "$MAYHEM_RUN_DIR/running.tunnels"; then
		mayhem_tunnels_sync "$MAYHEM_RUN_DIR/running.tunnels" "$MAYHEM_RUN_DIR/tunnels"
		cp "$MAYHEM_RUN_DIR/tunnels" "$MAYHEM_RUN_DIR/running.tunnels" 2>/dev/null
	fi

	# New names of the rules (a section, a geo update): dnsmasq sends them to
	# xray from now on.
	mayhem_dns_servers xray

	return 0
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

# Kill switch (settings.killswitch): nothing goes direct when the servers,
# the remote DNS, a tunnel or xray itself fail; the traffic waits instead.
mayhem_killswitch() {
	grep -q '^MAYHEM_KILLSWITCH=1$' "$MAYHEM_RUN_DIR/env" 2>/dev/null
}

# --- tunnel sections ---------------------------------------------------------
# $MAYHEM_RUN_DIR/tunnels: "section device mark table v6 [bal]" per line. In kernel
# mode, marked packets use the section's routing table, which holds a default
# route into the device only while the tunnel works: otherwise the lookup
# falls through to the main table and the traffic goes direct. The xray path
# of every tunnel section is a balancer that is pointed at "direct" meanwhile.

mayhem_tunnels_up() {
	local name dev mark table v6

	[ -s "$MAYHEM_RUN_DIR/tunnels" ] || return 0

	while read -r name dev mark table v6 bal; do
		[ "$mark" = - ] && continue
		ip rule add fwmark "$mark/$MAYHEM_TUN_MASK" table "$table" priority "$MAYHEM_TUN_RULE_PRIO"
		[ "$v6" = 1 ] && ip -6 rule add fwmark "$mark/$MAYHEM_TUN_MASK" table "$table" priority "$MAYHEM_TUN_RULE_PRIO"
	done < "$MAYHEM_RUN_DIR/tunnels"

	rm -f "$MAYHEM_RUN_DIR"/tunnel.*
	mayhem_tunnels_check force
	return 0
}

# Is the rule of a tunnel table in place? $1 4|6, $2 mark, $3 table.
mayhem_tun_rule_has() {
	ip -"$1" rule show priority "$MAYHEM_TUN_RULE_PRIO" 2>/dev/null | grep -q "fwmark $2/$MAYHEM_TUN_MASK lookup $3\( \|\$\)"
}

# Reload: from the tunnels of $1 (in use) to those of $2. A tunnel that
# stays keeps its rule, its route and its state: taking all of them down
# and up again sent the traffic of every tunnel direct for as long as the
# checks took (seconds per idle tunnel). Only new tunnels are checked here.
mayhem_tunnels_sync() {
	local old="$1" new="$2" name dev mark table v6 bal flushed="" line

	[ -s "$new" ] || { mayhem_tunnels_down; return 0; }

	# New lines: their rules first, then their state.
	while read -r name dev mark table v6 bal; do
		line="$name $dev $mark $table $v6${bal:+ $bal}"
		grep -qxF "$line" "$old" 2>/dev/null && continue
		rm -f "$MAYHEM_RUN_DIR/tunnel.$name" "$MAYHEM_RUN_DIR/tunnel.$name.sel"
		[ "$mark" = - ] && continue
		mayhem_tun_rule_has 4 "$mark" "$table" ||
			ip rule add fwmark "$mark/$MAYHEM_TUN_MASK" table "$table" priority "$MAYHEM_TUN_RULE_PRIO"
		if [ "$v6" = 1 ]; then
			mayhem_tun_rule_has 6 "$mark" "$table" ||
				ip -6 rule add fwmark "$mark/$MAYHEM_TUN_MASK" table "$table" priority "$MAYHEM_TUN_RULE_PRIO"
		fi
	done < "$new"

	# Lines that are gone: their rules, and their tables unless a new line
	# uses the same one.
	[ -s "$old" ] && while read -r name dev mark table v6 bal; do
		line="$name $dev $mark $table $v6${bal:+ $bal}"
		grep -qxF "$line" "$new" && continue
		awk -v n="$name" '$1 == n { f = 1 } END { exit !f }' "$new" || rm -f "$MAYHEM_RUN_DIR/tunnel.$name" "$MAYHEM_RUN_DIR/tunnel.$name.sel"
		[ "$mark" = - ] && continue
		if ! awk -v m="$mark" -v t="$table" '$3 == m && $4 == t { f = 1 } END { exit !f }' "$new"; then
			ip rule del fwmark "$mark/$MAYHEM_TUN_MASK" table "$table" priority "$MAYHEM_TUN_RULE_PRIO" 2>/dev/null
			ip -6 rule del fwmark "$mark/$MAYHEM_TUN_MASK" table "$table" priority "$MAYHEM_TUN_RULE_PRIO" 2>/dev/null
		fi
		case " $flushed " in *" $table "*) continue ;; esac
		if ! awk -v t="$table" '$4 == t { f = 1 } END { exit !f }' "$new"; then
			ip route flush table "$table" 2>/dev/null
			ip -6 route flush table "$table" 2>/dev/null
			flushed="$flushed $table"
		fi
	done < "$old"

	# The state of new tunnels (and routes of the tables they took over).
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

	while read -r name dev mark table v6 bal; do
		was="$(cat "$MAYHEM_RUN_DIR/tunnel.$name" 2>/dev/null)"

		if mayhem_tunnel_ok "$dev"; then
			state=up

			if [ "$table" != - ]; then
				ip route replace default dev "$dev" table "$table" 2>/dev/null
				[ "$v6" = 1 ] && ip -6 route replace default dev "$dev" table "$table" 2>/dev/null
			fi

			# bal 0: a server of a proxy section, chosen by hand; its
			# balancer keeps the choice.
			if [ "$was" != up ] && [ "${bal:-1}" != 0 ]; then
				mayhem_select "bal-$name" ""
				[ -n "$was" ] && mayhem_log "tunnel $dev of section $name works again"
			fi
		elif mayhem_killswitch; then
			# The traffic stays with the tunnel and waits for it: its
			# route stays (a blackhole when the device is gone), its
			# balancer keeps the tunnel.
			state=held

			if [ "$table" != - ]; then
				ip route replace default dev "$dev" table "$table" 2>/dev/null ||
					ip route replace blackhole default table "$table" 2>/dev/null
				if [ "$v6" = 1 ]; then
					ip -6 route replace default dev "$dev" table "$table" 2>/dev/null ||
						ip -6 route replace blackhole default table "$table" 2>/dev/null
				fi
			fi

			[ "$was" = down ] && [ "${bal:-1}" != 0 ] && mayhem_select "bal-$name" ""
			[ "$was" != held ] && mayhem_log "tunnel $dev of section $name does not work, its traffic waits for it (kill switch)" warn
		else
			state=down

			if [ "$table" != - ]; then
				ip route flush table "$table" 2>/dev/null
				ip -6 route flush table "$table" 2>/dev/null
			fi

			# Again only when xray is another process now: every call is
			# one more xray (`xray api`, ~30 MB for a moment).
			xpid="$(cat "$MAYHEM_RUN_DIR/xray.pid" 2>/dev/null)"

			if [ "${bal:-1}" = 0 ]; then
				:
			elif [ "$was" != down ] || [ "$(cat "$MAYHEM_RUN_DIR/tunnel.$name.sel" 2>/dev/null)" != "$xpid" ]; then
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

# Once a day at the nightly update hour: the DNS of running xray lacks names
# of servers that came with subscriptions since it started (they are not
# worth a restart in the day, see the restart key in build.uc). Then xray is
# restarted with them, while the network sleeps.
mayhem_dns_catchup() {
	local hour day stamp="$MAYHEM_RUN_DIR/dns-catchup.day"

	[ -f "$MAYHEM_RUN_DIR/active" ] || return 0
	hour="$(uci -q get mayhem.geo.update_hour)"
	[ "$(date +%H)" -eq "${hour:-4}" ] 2>/dev/null || return 0

	day="$(date +%Y%m%d)"
	[ "$(cat "$stamp" 2>/dev/null)" = "$day" ] && return 0
	echo "$day" > "$stamp"

	cmp -s "$MAYHEM_RUN_DIR/xray.key" "$MAYHEM_RUN_DIR/running.xray.key" || return 0
	# shellcheck disable=SC2016 # ucode code, not shell
	ucode -e 'const fs = require("fs"); const d = (f) => sprintf("%J", json(fs.readfile(f) ?? "{}").dns);
		exit(d(ARGV[0]) == d(ARGV[1]) ? 0 : 1);' "$MAYHEM_RUN_DIR/xray.json" "$MAYHEM_RUN_DIR/running.xray.json" 2>/dev/null && return 0

	mayhem_log "the DNS of xray gets the names of new servers: restarting xray at the update hour"
	mayhem_restart_why "config:dns"
	: > "$MAYHEM_RUN_DIR/restart.pending"
	/etc/init.d/mayhem reload
}

# The connection log of xray (conn.log): every connection xray takes and every
# DNS answer it gives. It is always a file, so the dashboard knows the names
# and servers of connections opened before its window; mayhem_conn_fold keeps
# only what it needs. An older xray-run left /dev/null there: xray opens the
# path again when its logger restarts, so no restart of xray is needed.
mayhem_conn_log() {
	local f="$MAYHEM_RUN_DIR/conn.log"

	[ -f "$f" ] && [ ! -L "$f" ] && return 0
	: > "$f.new" && mv -f "$f.new" "$f"

	[ -n "$(cat "$MAYHEM_RUN_DIR/xray.pid" 2>/dev/null)" ] &&
		"$MAYHEM_XRAY_BIN" api restartlogger --server="127.0.0.1:$MAYHEM_API_PORT" >/dev/null 2>&1
	return 0
}

# Folds conn.log into conn.names and empties it (the scheduler every minute,
# the dashboard when the log grows). conn.names: "d <address> <name>" - which
# name a DNS answer gave the address; "c <tcp|udp> <ip>:<port> <tag>" - which
# outbound xray took for a connection from there. The last MAYHEM_CONN_NAMES
# of each kind. Fake addresses of FakeDNS say nothing and are left out. A line
# xray writes between the fold and the cut is lost - rarely, and it only
# costs a name.
mayhem_conn_fold() {
	local f="$MAYHEM_RUN_DIR/conn.log" m="$MAYHEM_RUN_DIR/conn.names" size

	[ -f "$f" ] && [ ! -L "$f" ] || return 0
	size="$(wc -c < "$f" 2>/dev/null)"
	[ "${size:-0}" -gt 0 ] || return 0

	{ [ -f "$m" ] && cat "$m"; head -c "$size" "$f"; } | awk -v max="${MAYHEM_CONN_NAMES:-3000}" '
		function put(kind, key, line) {
			if (key in seq)
				delete out[seq[key]]
			seq[key] = ++n
			out[n] = line
			kd[n] = kind
		}
		$1 == "d" && NF == 3 { put("d", "d " $2, $0); next }
		$1 == "c" && NF == 4 { put("c", "c " $2 " " $3, $0); next }
		/ (got answer|cache HIT|cache OPTIMISTE): / {
			i = index($0, ": ")
			rest = substr($0, i + 2)
			name = rest
			sub(/ .*/, "", name)
			sub(/\.$/, "", name)
			lb = index(rest, "[")
			rb = index(rest, "]")
			if (name == "" || !lb || rb <= lb)
				next
			k = split(substr(rest, lb + 1, rb - lb - 1), ips, ", ")
			for (j = 1; j <= k; j++)
				if (ips[j] != "" && ips[j] !~ /^198\.1[89]\./)
					put("d", "d " ips[j], "d " ips[j] " " name)
			next
		}
		/ accepted (tcp|udp):.* \[/ {
			for (j = 1; j <= NF; j++)
				if ($j == "from")
					break
			src = $(j + 1)
			net = $(j + 3)
			sub(/^(tcp|udp):/, "", src)
			gsub(/[][]/, "", src)
			sub(/:.*/, "", net)
			det = substr($0, index($0, " accepted ") + 10)
			det = substr(det, index(det, " [") + 2)
			sub(/\].*/, "", det)
			tag = det
			sub(/.* /, "", tag)
			if (src != "" && tag != "" && (net == "tcp" || net == "udp"))
				put("c", "c " net " " src, "c " net " " src " " tag)
		}
		END {
			for (i = n; i >= 1; i--)
				if (i in out && ++cnt[kd[i]] > max)
					delete out[i]
			for (i = 1; i <= n; i++)
				if (i in out)
					print out[i]
		}' > "$m.new" && mv -f "$m.new" "$m"

	# What xray wrote meanwhile stays.
	tail -c +"$((size + 1))" "$f" > "$f.t" 2>/dev/null && cat "$f.t" > "$f"
	rm -f "$f.t"
	return 0
}

# --- why xray restarted ------------------------------------------------------------
# A restart Mayhem causes leaves its reason for the dashboard: xray-run takes it
# when the new xray is up (xray.started). Reasons: config:<parts>, servers,
# geo, memory, hang, manual.
mayhem_restart_why() {
	mkdir -p "$MAYHEM_RUN_DIR"
	echo "$(date +%s) $1" > "$MAYHEM_RUN_DIR/restart.why"
}

# On reload, before procd compares its files: a running xray that is about to
# be restarted, and why.
mayhem_restart_reason() {
	local pid why

	pid="$(cat "$MAYHEM_RUN_DIR/xray.pid" 2>/dev/null)"
	[ -n "$pid" ] && kill -0 "$pid" 2>/dev/null || return 0

	why="$(ucode "$MAYHEM_LIB_DIR/why.uc" 2>/dev/null)"

	if [ -z "$why" ] && [ -f "$MAYHEM_RUN_DIR/running.geo.stamp" ] &&
	   ! cmp -s "$MAYHEM_RUN_DIR/geo.stamp" "$MAYHEM_RUN_DIR/running.geo.stamp"; then
		why=geo
	fi

	[ -n "$why" ] && mayhem_restart_why "$why"

	return 0
}

# xray is up: when it started and why (a reason noted in the last 5 minutes,
# or how the previous xray ended), in xray.started and in the system log: a
# restart cuts every connection, the log says which change caused it.
mayhem_xray_started() {
	local now why t r

	now="$(date +%s)"
	why=""

	# shellcheck disable=SC2046
	set -- $(cat "$MAYHEM_RUN_DIR/restart.why" 2>/dev/null)
	if [ -n "${1:-}" ] && [ $(( now - $1 )) -lt 300 ]; then
		why="${2:-}"
	else
		# shellcheck disable=SC2046
		set -- $(cat "$MAYHEM_RUN_DIR/xray.exit" 2>/dev/null)
		[ -n "${1:-}" ] && [ $(( now - $1 )) -lt 300 ] && why="exit:${2:-?}"
	fi

	rm -f "$MAYHEM_RUN_DIR/restart.why" "$MAYHEM_RUN_DIR/xray.exit" "$MAYHEM_RUN_DIR/xray.error"
	echo "$now $why" > "$MAYHEM_RUN_DIR/xray.started"
	[ -n "$why" ] && mayhem_log "xray started again: $why"
	return 0
}

# xray quit before it listened: its error message (xray run -test, only now).
mayhem_xray_error() {
	"$MAYHEM_XRAY_BIN" run -test -c "$MAYHEM_RUN_DIR/running.xray.json" 2>&1 |
		grep -v -e '^Xray ' -e '^A unified platform' -e 'Reading config' -e 'deprecated' | tail -n 3 | cut -c 1-400 > "$MAYHEM_RUN_DIR/xray.error"
}

# Memory xray's heap freed (closed connections, a burst of blocked ones) goes
# back to the system after a garbage collection, which Go starts when the heap
# grows or every two minutes. Once a minute: with more than 8 MiB freed but
# kept (HeapIdle - HeapReleased), a collection is started at once through
# xray's metrics port (pprof's "gc=1"), and Go hands the pages back.
mayhem_mem_trim() {
	local vars idle rel

	[ -f "$MAYHEM_RUN_DIR/active" ] || return 0

	vars="$(curl -s -m 5 "http://127.0.0.1:$MAYHEM_METRICS_PORT/debug/vars" 2>/dev/null)" || return 0
	idle="$(printf '%s' "$vars" | grep -o '"HeapIdle": *[0-9]*' | head -n 1 | grep -o '[0-9]*$')"
	rel="$(printf '%s' "$vars" | grep -o '"HeapReleased": *[0-9]*' | head -n 1 | grep -o '[0-9]*$')"

	[ -n "$idle" ] && [ -n "$rel" ] || return 0

	if [ $(( idle - rel )) -gt $(( 8 * 1048576 )) ]; then
		curl -s -o /dev/null -m 20 "http://127.0.0.1:$MAYHEM_METRICS_PORT/debug/pprof/heap?gc=1" 2>/dev/null
		echo "$(date +%s) $(( (idle - rel) / 1024 ))" > "$MAYHEM_RUN_DIR/mem.trim"
	fi
}

# A new xray in place of the running one. xray-run starts it again with the
# interception in place: connections wait a moment instead of going direct
# (and past the kill switch). Without xray-run, xray itself is stopped and
# procd starts it again.
mayhem_xray_swap() {
	local runner

	runner="$(cat "$MAYHEM_RUN_DIR/xray-run.pid" 2>/dev/null)"

	if [ -n "$runner" ] && kill -0 "$runner" 2>/dev/null; then
		kill -HUP "$runner"
	else
		kill -TERM "$1"
	fi
}

mayhem_watchdog() {
	local pid rss total pct limit n gml

	[ "${MAYHEM_WATCHDOG:-$(uci -q get mayhem.settings.watchdog)}" = 0 ] && return 0

	pid="$(cat "$MAYHEM_RUN_DIR/xray.pid" 2>/dev/null)"

	if [ -n "$pid" ] && [ -d "/proc/$pid" ]; then
		# RssAnon: the memory xray took. VmRSS also counts ~20 MB of its own
		# code read from flash, which the kernel drops and reads again.
		rss="$(awk '/^RssAnon:/ { print $2 }' "/proc/$pid/status" 2>/dev/null)"
		[ -n "$rss" ] || rss="$(awk '/^VmRSS:/ { print $2 }' "/proc/$pid/status" 2>/dev/null)"
		total="$(awk '/^MemTotal:/ { print $2 }' /proc/meminfo)"
		pct="${MAYHEM_WATCHDOG_MEM:-$(uci -q get mayhem.settings.watchdog_mem)}"
		limit=$(( ${total:-0} * ${pct:-40} / 100 ))
		# xray's own limit (GOMEMLIMIT) is where its garbage collector holds
		# it: a lower watchdog limit would restart xray for using what it was
		# allowed to. A quarter above it at least, unless the limit is given
		# explicitly (MAYHEM_WATCHDOG_MEM).
		gml="$(sed -n 's/^GOMEMLIMIT=\([0-9]*\)MiB$/\1/p' "$MAYHEM_RUN_DIR/env" 2>/dev/null)"
		[ -z "${MAYHEM_WATCHDOG_MEM:-}" ] && [ -n "$gml" ] && [ "$limit" -lt $(( gml * 1024 * 5 / 4 )) ] &&
			limit=$(( gml * 1024 * 5 / 4 ))

		if [ "${rss:-0}" -gt "$limit" ]; then
			n=$(( $(cat "$MAYHEM_RUN_DIR/watchdog.mem" 2>/dev/null || echo 0) + 1 ))

			if [ "$n" -ge 3 ]; then
				mayhem_log "xray has used ${rss} KiB for 3 minutes (limit ${limit} KiB), restarting it" warn
				mayhem_watchdog_note "xray restarted: ${rss} KiB of memory"
				mayhem_restart_why memory
				n=0
				mayhem_xray_swap "$pid"
			fi

			echo "$n" > "$MAYHEM_RUN_DIR/watchdog.mem"
		else
			echo 0 > "$MAYHEM_RUN_DIR/watchdog.mem"
		fi

		# A hung xray (alive, but it does not answer): DNS and the listed
		# sites stop while it is there. Three minutes without an answer on
		# its own metrics port, and it is restarted in place.
		if [ -f "$MAYHEM_RUN_DIR/active" ]; then
			# Counted per xray process ("pid count"): a count left from a
			# process that is gone does not carry over.
			if ! kill -0 "$pid" 2>/dev/null; then
				rm -f "$MAYHEM_RUN_DIR/watchdog.hang"
			elif curl -s -o /dev/null -m 5 "http://127.0.0.1:$MAYHEM_METRICS_PORT/debug/vars" 2>/dev/null; then
				rm -f "$MAYHEM_RUN_DIR/watchdog.hang"
			else
				n=1
				# shellcheck disable=SC2046
				set -- $(cat "$MAYHEM_RUN_DIR/watchdog.hang" 2>/dev/null)
				if [ "${1:-}" = "$pid" ]; then
					n=$(( ${2:-0} + 1 ))
				fi
				echo "$pid $n" > "$MAYHEM_RUN_DIR/watchdog.hang"

				if [ "$n" -ge 3 ]; then
					mayhem_log "xray has not answered for 3 minutes, restarting it" warn
					mayhem_watchdog_note "xray restarted: it did not answer"
					mayhem_restart_why hang
					rm -f "$MAYHEM_RUN_DIR/watchdog.hang"
					mayhem_xray_swap "$pid"
					sleep 5
					# A stopped or wedged process may ignore TERM.
					kill -0 "$pid" 2>/dev/null && kill -KILL "$pid"
				fi
			fi
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
# dnsmasq gets one file in its conf-dir under /tmp (nothing on flash, a reboot
# always returns plain DNS): no-resolv, the nftset lines of tunnel sections
# and servers-file=$MAYHEM_DNS_SERVERS (inside dnsmasq's jail). The file is put in place when
# the service starts and dnsmasq restarts only when it changed. Which servers
# dnsmasq asks - xray, or the provider's while xray is down - lives in
# that file, which dnsmasq reads again on SIGHUP: switching takes no
# restart, and DNS never stops while xray starts, restarts or crashes.

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

# The provider's DNS servers as dnsmasq would use them without Mayhem.
mayhem_isp_dns() {
	local f="${MAYHEM_RESOLV_AUTO:-/tmp/resolv.conf.d/resolv.conf.auto}" ip found=""

	found="$(awk '$1 == "nameserver" && $2 !~ /^(127\.|::1$)/ { print "server=" $2 }' "$f" 2>/dev/null)"

	if [ -n "$found" ]; then
		echo "$found"
		return 0
	fi

	for ip in $(uci -q get mayhem.dns.domestic) 77.88.8.8 77.88.8.1; do
		case "$ip" in
			*[!0-9a-fA-F.:]*) continue ;;
		esac
		echo "server=$ip"
	done
}

mayhem_dnsmasq_hup() {
	local pids

	pids="$(pidof dnsmasq 2>/dev/null)"
	# shellcheck disable=SC2086
	[ -n "$pids" ] && kill -HUP $pids 2>/dev/null
	return 0
}

# Where dnsmasq sends queries: "xray" or "isp". HUP only when it changes.
# With xray: dns.xray from the generator - either everything to xray, or only
# the names of the rules, with "@ISP@" standing for the provider's servers
# for everything else.
mayhem_dns_servers() {
	local f="$MAYHEM_DNS_SERVERS" new="$MAYHEM_DNS_SERVERS.new"

	mkdir -p "$MAYHEM_RUN_DIR" "$(dirname "$MAYHEM_DNS_SERVERS")"

	local src="$MAYHEM_RUN_DIR/dns.xray"

	# The remote DNS does not answer and the kill switch is off (health.uc):
	# its names go to the provider.
	[ -f "$MAYHEM_RUN_DIR/dns.degraded" ] && [ -s "$MAYHEM_RUN_DIR/dns.fallback" ] && src="$MAYHEM_RUN_DIR/dns.fallback"

	if [ "$1" = xray ] && [ -s "$src" ]; then
		mayhem_isp_dns > "$new.isp"
		sed -e "/^@ISP@\$/{r $new.isp" -e 'd;}' "$src" > "$new"
		rm -f "$new.isp"
	elif [ "$1" = xray ]; then
		echo "server=127.0.0.1#$MAYHEM_DNS_PORT" > "$new"
	else
		mayhem_isp_dns > "$new"
	fi

	# dnsmasq reads it again on SIGHUP as its own user, not root.
	chmod 644 "$new"

	if cmp -s "$new" "$f"; then
		# One written by an older Mayhem may be root's only.
		chmod 644 "$f"
		rm -f "$new"
		return 0
	fi

	mv -f "$new" "$f"
	mayhem_dnsmasq_hup
}

# Puts Mayhem's file into dnsmasq's conf-dir; restarts dnsmasq only when the
# file is new or changed (tunnel domains, first start).
mayhem_dns_up() {
	local d changed=0

	# xray-run switches dnsmasq to xray once xray listens.
	mkdir -p "$(dirname "$MAYHEM_DNS_SERVERS")"

	if [ ! -f "$MAYHEM_DNS_SERVERS" ] || [ ! -f "$MAYHEM_RUN_DIR/active" ]; then
		mayhem_isp_dns > "$MAYHEM_DNS_SERVERS.tmp" && chmod 644 "$MAYHEM_DNS_SERVERS.tmp" &&
			mv -f "$MAYHEM_DNS_SERVERS.tmp" "$MAYHEM_DNS_SERVERS"
	fi

	for d in $(mayhem_dnsmasq_dirs); do
		mkdir -p "$d" || continue
		cmp -s "$MAYHEM_RUN_DIR/dnsmasq.conf" "$d/$MAYHEM_DNSMASQ_FILE" && continue

		# A hard link when the conf-dir is on the same tmpfs: with tunnel
		# sections the file holds every domain of their lists.
		rm -f "$d/$MAYHEM_DNSMASQ_FILE"
		ln "$MAYHEM_RUN_DIR/dnsmasq.conf" "$d/$MAYHEM_DNSMASQ_FILE" 2>/dev/null ||
			cp "$MAYHEM_RUN_DIR/dnsmasq.conf" "$d/$MAYHEM_DNSMASQ_FILE"
		changed=1
	done

	[ "$changed" = 1 ] && "$MAYHEM_DNSMASQ_INIT" restart >/dev/null 2>&1

	return 0
}

mayhem_dns_down() {
	local d changed=0

	for d in $(mayhem_dnsmasq_dirs) /tmp/dnsmasq.d; do
		if [ -f "$d/$MAYHEM_DNSMASQ_FILE" ]; then
			rm -f "$d/$MAYHEM_DNSMASQ_FILE"
			changed=1
		fi
	done

	rm -f "$MAYHEM_DNS_SERVERS"
	[ "$changed" = 1 ] && "$MAYHEM_DNSMASQ_INIT" restart >/dev/null 2>&1

	return 0
}

# --- locks and background jobs -------------------------------------------------

# One holder of the lock $1 at a time ($MAYHEM_RUN_DIR/$1.lock with its pid).
# A lock left by a process that is gone is taken over; after $2 seconds (300)
# it is taken anyway.
mayhem_lock() {
	local d="$MAYHEM_RUN_DIR/$1.lock" i=0 pid

	mkdir -p "$MAYHEM_RUN_DIR"

	while ! mkdir "$d" 2>/dev/null; do
		pid="$(cat "$d/pid" 2>/dev/null)"

		if { [ -n "$pid" ] && ! kill -0 "$pid" 2>/dev/null; } || [ "$i" -ge "${2:-300}" ]; then
			rm -rf "$d"
			continue
		fi

		sleep 1
		i=$((i + 1))
	done

	echo "$$" > "$d/pid"
}

mayhem_unlock() {
	local d="$MAYHEM_RUN_DIR/$1.lock"

	[ "$(cat "$d/pid" 2>/dev/null)" = "$$" ] && rm -rf "$d"
	return 0
}

# Subscriptions not downloaded yet or given a new address (subs.new from the
# generator) are downloaded in the background right after a reload, once
# xray works (the download goes through it), and then the service reloads
# with their servers. Meanwhile the dashboard shows the change on its way
# (applying.sub). A failed address is tried again on the scheduler's terms.
mayhem_subs_new() {
	[ -s "$MAYHEM_RUN_DIR/subs.new" ] || return 0

	(
		f="$MAYHEM_RUN_DIR/applying.sub"
		: > "$f"
		# procd restarts xray after the reload, when it has to.
		sleep 3
		i=0
		while [ ! -f "$MAYHEM_RUN_DIR/active" ] && [ "$i" -lt 60 ]; do
			sleep 1
			i=$((i + 1))
		done
		ucode "$MAYHEM_SUB" update --new >/dev/null 2>&1
		rc=$?
		rm -f "$f"
		[ "$rc" = 3 ] && /etc/init.d/mayhem reload
	) >/dev/null 2>&1 </dev/null &
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

	# Any other TPROXY ruleset (unknown clients) is a conflict as well. -t
	# leaves out the elements of the sets: with a big geoip category the full
	# dump took a second on every reload.
	if nft -t list ruleset 2>/dev/null | awk -v t="$MAYHEM_NFT_TABLE" '
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

	# A restart asked for (mayhem_dns_catchup): the new key makes procd do it.
	if [ -f "$MAYHEM_RUN_DIR/restart.pending" ]; then
		rm -f "$MAYHEM_RUN_DIR/restart.pending"
		echo "restart $(date +%s)" >> "$MAYHEM_RUN_DIR/xray.key"
		return 0
	fi

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

mayhem_fw_release() {
	# Sets FW_VERSION, FW_TARGET (target/subtarget) and FW_ARCH (package
	# architecture). `ubus call system board` has no arch at all, so the
	# release file comes first and the package manager fills the gaps.
	local f="${MAYHEM_RELEASE_FILE:-/etc/openwrt_release}" board

	# shellcheck source=/dev/null
	FW_VERSION="$(. "$f" 2>/dev/null; echo "$DISTRIB_RELEASE")"
	# shellcheck source=/dev/null
	FW_TARGET="$(. "$f" 2>/dev/null; echo "$DISTRIB_TARGET")"
	# shellcheck source=/dev/null
	FW_ARCH="$(. "$f" 2>/dev/null; echo "$DISTRIB_ARCH")"

	if [ -z "$FW_VERSION" ] || [ -z "$FW_TARGET" ]; then
		board="$(ubus call system board 2>/dev/null)"
		[ -n "$FW_VERSION" ] || FW_VERSION="$(echo "$board" | jsonfilter -e '@.release.version' 2>/dev/null)"
		[ -n "$FW_TARGET" ] || FW_TARGET="$(echo "$board" | jsonfilter -e '@.release.target' 2>/dev/null)"
	fi

	if [ -z "$FW_ARCH" ]; then
		if command -v apk >/dev/null 2>&1; then
			FW_ARCH="$(apk --print-arch 2>/dev/null)"
		elif command -v opkg >/dev/null 2>&1; then
			# the architecture with the highest priority, not "all" or "noarch"
			FW_ARCH="$(opkg print-architecture 2>/dev/null | awk '$3 > max { max = $3; a = $2 } END { print a }')"
		fi
	fi

	[ -n "$FW_VERSION" ] && [ -n "$FW_TARGET" ] && [ -n "$FW_ARCH" ]
}

mayhem_dnsmasq_nftset() {
	# Whether dnsmasq can fill nftables sets. A build without it lists
	# "no-nftset" among its options: the option must be a whole word.
	dnsmasq --version 2>/dev/null | grep -qE '(^|[[:space:]])nftset([[:space:]]|$)'
}
