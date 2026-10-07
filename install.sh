#!/bin/sh
# Project Mayhem installer / updater for OpenWrt 24.10 (opkg) and 25.12+ (apk).
#
#   sh <(wget -O - https://raw.githubusercontent.com/OWNER/project-mayhem/main/install.sh)
#
# Set MAYHEM_REPO=owner/repo to install from a fork.

REPO="${MAYHEM_REPO:-OWNER/project-mayhem}"
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
		apk info -e "$1" >/dev/null 2>&1
	else
		opkg list-installed "$1" 2>/dev/null | grep -q "^$1 "
	fi
}

fetch() {
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

	case "$REPO" in
		OWNER/*) die "The installer has no repository set. Run it from the project page link or set MAYHEM_REPO." ;;
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
	local upgrade=0 conflicts

	check_system
	[ -x /etc/init.d/mayhem ] && upgrade=1

	msg "Updating package lists..."
	pkg_update || die "Package list update failed."

	msg "Downloading Mayhem from $REPO..."
	download_release
	install_packages
	rm -rf "$TMP"

	msg "Installing xray..."
	/usr/bin/mayhem xray-install || die "xray installation failed, run 'mayhem xray-install' later."

	/etc/init.d/mayhem enable
	/etc/init.d/rpcd restart >/dev/null 2>&1
	rm -rf /tmp/luci-indexcache* /tmp/luci-modulecache

	. /usr/share/mayhem/lib.sh
	conflicts="$(mayhem_conflicts)"

	if [ "$upgrade" = 1 ]; then
		/etc/init.d/mayhem restart
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
