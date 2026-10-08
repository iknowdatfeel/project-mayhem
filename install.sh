#!/bin/sh
# Project Mayhem installer / updater for OpenWrt 24.10 (opkg) and 25.12+ (apk).
#
#   sh <(wget -O - https://raw.githubusercontent.com/iknowdatfeel/project-mayhem/main/install.sh)
#
# Set MAYHEM_REPO=owner/repo to install from a fork.

REPO="${MAYHEM_REPO:-iknowdatfeel/project-mayhem}"
API="https://api.github.com/repos/$REPO/releases/latest"
TMP="/tmp/mayhem-install"
TRIES=3

msg()  { printf '\033[32;1m%s\033[0m\n' "$1"; }
warn() { printf '\033[33;1m%s\033[0m\n' "$1"; }
die()  { printf '\033[31;1m%s\033[0m\n' "$1" >&2; rm -rf "$TMP"; exit 1; }

PKG=opkg
command -v apk >/dev/null 2>&1 && PKG=apk

pkg_update() {
	if [ "$PKG" = apk ]; then apk update; else opkg update; fi
}

pkg_install_file() {
	if [ "$PKG" = apk ]; then
		# Release packages are not signed with an OpenWrt key.
		apk add --allow-untrusted "$1"
	else
		opkg install "$1"
	fi
}

pkg_installed() {
	if [ "$PKG" = apk ]; then
		apk list --installed 2>/dev/null | grep -q "^$1-[0-9]"
	else
		opkg list-installed 2>/dev/null | grep -q "^$1 - "
	fi
}

# Would the package install from the configured feeds (matching kernel and arch)?
pkg_installable() {
	if [ "$PKG" = apk ]; then
		apk add --simulate "$1" >/dev/null 2>&1
	else
		opkg install --noaction "$1" >/dev/null 2>&1
	fi
}

# Everything Mayhem needs, checked before anything is installed.
DEPS="ucode ucode-mod-fs ucode-mod-uci kmod-nft-tproxy ca-bundle unzip curl rpcd-mod-ucode luci-base"

check_deps() {
	local p missing=""

	for p in $DEPS; do
		pkg_installed "$p" && continue
		pkg_installable "$p" || missing="$missing $p"
	done

	[ -z "$missing" ] && return 0

	case "$missing" in
		*kmod-*)
			warn "Kernel modules cannot be installed:${missing}."
			warn "Usually the firmware is a custom or snapshot build whose kernel does not match the package feeds."
			warn "Use an official OpenWrt image of the same version, or a firmware built with kmod-nft-tproxy."
			;;
	esac

	die "Missing packages that cannot be installed:${missing}. Nothing was changed."
}

# The kernel must accept a TPROXY rule, otherwise interception cannot work.
check_tproxy() {
	local rc

	printf '%s\n' \
		'table inet mayhem_probe {' \
		'	chain probe {' \
		'		type filter hook prerouting priority mangle; policy accept;' \
		'		meta l4proto tcp ip daddr 127.0.0.2 tproxy ip to 127.0.0.1:1' \
		'	}' \
		'}' | nft -f - >/dev/null 2>&1
	rc=$?
	nft delete table inet mayhem_probe >/dev/null 2>&1

	return "$rc"
}

fetch() {
	# MAYHEM_PROXY: an update run by Mayhem downloads through Xray first.
	if [ -n "${MAYHEM_PROXY:-}" ] && command -v curl >/dev/null 2>&1 && curl -fsSL -m 300 -x "$MAYHEM_PROXY" -o "$2" "$1" 2>/dev/null; then
		return 0
	fi

	if command -v curl >/dev/null 2>&1; then
		curl -fsSL -o "$2" "$1"
	else
		wget -q -O "$2" "$1"
	fi
}

check_system() {
	local release major avail_tmp avail_overlay need

	[ -f /etc/openwrt_release ] || die "This is not OpenWrt."
	release="$(. /etc/openwrt_release; echo "$DISTRIB_RELEASE")"
	major="${release%%.*}"

	msg "Router: $(cat /tmp/sysinfo/model 2>/dev/null), OpenWrt $release, package manager: $PKG"

	case "$major" in
		24|25|26|27) ;;
		SNAPSHOT) warn "SNAPSHOT builds are not tested." ;;
		*) die "OpenWrt $release is not supported, 24.10 or newer is required." ;;
	esac

	avail_tmp="$(df -k /tmp | awk 'NR == 2 { print $4 }')"
	[ "${avail_tmp:-0}" -ge 30720 ] || die "Need 30 MB free in RAM (/tmp) for the download, have $((avail_tmp / 1024)) MB."

	# xray is ~36 MB unpacked; skip the check when it is already installed.
	need=2048
	[ -x /usr/libexec/mayhem/xray ] || need=40960
	avail_overlay="$(df -k /overlay 2>/dev/null | awk 'NR == 2 { print $4 }')"
	[ -n "$avail_overlay" ] || avail_overlay="$(df -k / | awk 'NR == 2 { print $4 }')"

	if [ "${avail_overlay:-0}" -lt "$need" ]; then
		die "Need $((need / 1024)) MB of free flash, have $((avail_overlay / 1024)) MB. Remove unused packages (for example another proxy client) and run the installer again."
	fi

	nslookup github.com >/dev/null 2>&1 || die "DNS does not work on the router."

	# TLS downloads fail with a wrong clock.
	ntpd -q -n -p 194.190.168.1 -p 216.239.35.0 -p 162.159.200.1 >/dev/null 2>&1
}

download_release() {
	local list ext url file n

	ext=ipk
	[ "$PKG" = apk ] && ext=apk

	list="$(fetch "$API" - 2>/dev/null || wget -q -O - "$API")"
	echo "$list" | grep -q 'API rate limit' && die "GitHub API rate limit reached, try again in a few minutes."

	rm -rf "$TMP"
	mkdir -p "$TMP"

	for url in $(echo "$list" | grep -o "https://[^\"]*\.$ext" | sort -u); do
		file="$TMP/$(basename "$url")"
		n=0

		while [ "$n" -lt "$TRIES" ]; do
			fetch "$url" "$file" && [ -s "$file" ] && break
			n=$((n + 1))
			rm -f "$file"
		done

		[ -s "$file" ] || die "Could not download $url"
	done

	ls "$TMP"/mayhem[-_]*."$ext" >/dev/null 2>&1 || die "No $ext packages found in the latest release of $REPO."
}

install_packages() {
	local ext f

	ext=ipk
	[ "$PKG" = apk ] && ext=apk

	for f in "$TMP"/mayhem[-_]*."$ext" "$TMP"/luci-app-mayhem[-_]*."$ext"; do
		[ -f "$f" ] || continue
		msg "Installing $(basename "$f")..."
		pkg_install_file "$f" || die "Installation of $(basename "$f") failed."
	done

	for f in "$TMP"/luci-i18n-mayhem-ru[-_]*."$ext"; do
		[ -f "$f" ] || continue

		if pkg_installed luci-i18n-mayhem-ru; then
			pkg_install_file "$f"
		else
			msg "Install the Russian interface language? y/n"
			read -r answer
			case "$answer" in y|Y|yes|д|Д) pkg_install_file "$f" ;; esac
		fi
	done
}

main() {
	local upgrade=0 autostart=1 running=0 conflicts

	check_system

	# An update keeps the autostart and the running state as they were (the
	# old package's removal script stops and disables the service).
	if [ -x /etc/init.d/mayhem ]; then
		upgrade=1
		ls /etc/rc.d/S*mayhem >/dev/null 2>&1 || autostart=0
		/etc/init.d/mayhem running >/dev/null 2>&1 && running=1
	fi

	msg "Updating package lists..."
	pkg_update || die "Package list update failed."

	msg "Checking dependencies..."
	check_deps

	msg "Downloading Mayhem from $REPO..."
	download_release
	install_packages
	rm -rf "$TMP"

	if ! check_tproxy; then
		/etc/init.d/mayhem disable >/dev/null 2>&1
		die "The kernel rejects TPROXY rules even with kmod-nft-tproxy installed. Mayhem is installed but disabled: reboot the router and run the installer again."
	fi

	msg "Installing xray..."
	/usr/bin/mayhem xray-install || die "xray installation failed, run 'mayhem xray-install' later."

	[ "$autostart" = 1 ] && /etc/init.d/mayhem enable
	/etc/init.d/rpcd restart >/dev/null 2>&1
	rm -rf /tmp/luci-indexcache* /tmp/luci-modulecache

	. /usr/share/mayhem/lib.sh
	conflicts="$(mayhem_conflicts)"

	if [ "$upgrade" = 1 ]; then
		[ "$running" = 1 ] && /etc/init.d/mayhem restart
		msg "Mayhem is updated."
	else
		msg "Mayhem is installed and switched off."
		msg "Open LuCI → Services → Mayhem, add a server link to a section and enable routing."
	fi

	[ -n "$conflicts" ] &&
		warn "Running now: $conflicts. Mayhem will not start until it is stopped and disabled."

	msg "Clear the browser cache (Ctrl+F5) if the LuCI page looks outdated."
}

main "$@"
