#!/bin/sh
# Builds ucode at the version an OpenWrt release ships and installs it in
# PREFIX, with PREFIX/ucode as the command for the tests:
#   tests/build-ucode.sh 24.10 /opt/ucode-24.10
#   UCODE=/opt/ucode-24.10/ucode tests/run.sh
# RELEASE is an OpenWrt branch (24.10, 25.12, ...) or "master" for the latest
# ucode. Needs git, curl, cmake, json-c, libubox and libuci with headers
# (CMAKE_EXTRA can add -D options to find them). Only the fs and uci modules
# are built: the mayhem package depends on nothing else.

set -eu

rel="$1"
prefix="$2"
src="$(mktemp -d)"
trap 'rm -rf "$src"' EXIT

if [ "$rel" = master ]; then
	ref=HEAD
else
	ref="$(curl -fsSL "https://raw.githubusercontent.com/openwrt/openwrt/openwrt-$rel/package/utils/ucode/Makefile" |
		sed -n 's/^PKG_SOURCE_VERSION:=//p')"
	[ -n "$ref" ] || { echo "no ucode version found for OpenWrt $rel" >&2; exit 1; }
fi

git clone -q https://github.com/jow-/ucode.git "$src"
git -C "$src" checkout -q "$ref"

off=""
for m in DEBUG IO MATH NETADDR FFI UBUS RTNL NL80211 RESOLV STRUCT ULOOP LOG SOCKET SERIAL ZLIB DIGEST; do
	off="$off -D${m}_SUPPORT=OFF"
done

# shellcheck disable=SC2086
cmake -S "$src" -B "$src/build" -Wno-dev -DCMAKE_INSTALL_PREFIX="$prefix" \
	-DFS_SUPPORT=ON -DUCI_SUPPORT=ON $off ${CMAKE_EXTRA:-} >/dev/null
cmake --build "$src/build" --target install -j4 >/dev/null

# On OpenWrt (musl) `ucode script --opt` passes --opt to the script. glibc's
# getopt reorders the arguments and older ucode then takes --opt itself;
# POSIXLY_CORRECT makes glibc behave like musl.
cat > "$prefix/ucode" <<EOF
#!/bin/sh
POSIXLY_CORRECT=1 LD_LIBRARY_PATH="$prefix/lib\${LD_LIBRARY_PATH:+:\$LD_LIBRARY_PATH}" exec "$prefix/bin/ucode" "\$@"
EOF
chmod +x "$prefix/ucode"

echo "ucode $(git -C "$src" log -1 --format='%h %cs') ($rel) in $prefix"
