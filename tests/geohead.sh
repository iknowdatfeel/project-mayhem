#!/bin/sh
# Geo data from a local HTTP server: when the file has not changed (the same
# ETag / Last-Modified / Content-Length) and every category asked for is kept,
# a due update asks for the headers only; a changed file or a new category is
# downloaded.
#   UCODE=ucode tests/geohead.sh

set -u

ROOT="$(cd "$(dirname "$0")/.." && pwd)"
FILES="$ROOT/mayhem/files"
UCODE="${UCODE:-ucode}"
T="$(mktemp -d)"
fail=0
srv=""

ok() { printf 'ok   %s\n' "$1"; }
bad() {
	printf 'FAIL %s\n' "$1"
	fail=1
	if [ -n "${GITHUB_ACTIONS:-}" ]; then
		printf '::error title=%s::%s\n' "$(basename "$0")" "$1"
	fi
}
cleanup() { [ -n "$srv" ] && kill "$srv" 2>/dev/null; rm -rf "$T"; }
trap cleanup EXIT

mkdir -p "$T/www" "$T/uci" "$T/geo" "$T/run" "$T/bin"
printf '#!/bin/sh\nexit 0\n' > "$T/bin/logger"
chmod +x "$T/bin/logger"

mkdat() {
	# $1: categories "NAME=domain,domain;NAME=..."
	python3 -I -c "
import sys; sys.path.insert(0, sys.argv[1]); import mkdat
cats = [(c.split('=')[0], ['domain:' + d for d in c.split('=')[1].split(',')]) for c in sys.argv[3].split(';')]
open(sys.argv[2], 'wb').write(mkdat.geosite(cats))
" "$ROOT/tests/geo" "$T/www/geosite.dat" "$1"
}
mkdat 'YOUTUBE=youtube.test;OTHER=other.test'

port="$(python3 -I -c 'import socket; s = socket.socket(); s.bind(("127.0.0.1", 0)); print(s.getsockname()[1])')"
(cd "$T/www" && exec python3 -I -u -m http.server --bind 127.0.0.1 "$port") >"$T/http.log" 2>&1 &
srv=$!
i=0
while ! grep -q 'Serving' "$T/http.log" 2>/dev/null && [ "$i" -lt 50 ]; do sleep 0.1; i=$((i + 1)); done
sleep 0.3

uci() {
	# $1 categories of the section
	{
		printf "config geo 'geo'\n\toption via_xray '0'\n\n"
		printf "config geo_source 'hs'\n\toption kind 'geosite'\n\toption url 'http://127.0.0.1:%s/geosite.dat'\n\n" "$port"
		printf "config section 'main'\n\toption type 'proxy'\n\tlist link 'trojan://pw@de.example:443?sni=de.example#DE'\n"
		for c in $1; do printf "\tlist domain 'geosite:hs:%s'\n" "$c"; done
	} > "$T/uci/mayhem"
}
update() {
	PATH="$T/bin:$PATH" MAYHEM_UCI_DIR="$T/uci" MAYHEM_GEO_DIR="$T/geo" MAYHEM_RUN_DIR="$T/run" MAYHEM_TMP_DIR="$T" \
		"$UCODE" -L "$FILES/usr/share/ucode/*.uc" "$FILES/usr/share/mayhem/update.uc" geo hs >/dev/null 2>&1
}
# The last download a night ago: the update is due again.
age() {
	"$UCODE" -e "
		const fs = require('fs');
		const i = json(fs.readfile('$T/geo/hs.json')); i.updated = 1; fs.writefile('$T/geo/hs.json', sprintf('%J', i));
		const s = json(fs.readfile('$T/run/data-state.json')); s.geo.hs.last_ok = 1; fs.writefile('$T/run/data-state.json', sprintf('%J', s));
	"
}
gets() { grep -c '"GET /geosite.dat' "$T/http.log"; }
heads() { grep -c '"HEAD /geosite.dat' "$T/http.log"; }

uci youtube
update
if [ "$(gets)" = 1 ] && grep -q '"validator"' "$T/geo/hs.json"; then
	ok "first download keeps the file's headers"
else
	bad "first download: GET $(gets), index $(cat "$T/geo/hs.json" 2>/dev/null)"
fi

age
h="$(heads)"
update
rc=$?
if [ "$(gets)" = 1 ] && [ "$(heads)" -gt "$h" ] && [ "$rc" = 0 ]; then
	ok "unchanged file: only the headers, no download"
else
	bad "unchanged file: GET $(gets), HEAD $(heads), exit code $rc"
fi

uci 'youtube other'
update
if [ "$(gets)" = 2 ] && grep -q '"other"' "$T/geo/hs.json"; then
	ok "a new category: downloaded"
else
	bad "new category: GET $(gets)"
fi

age
sleep 1
mkdat 'YOUTUBE=youtube.test,yt.test;OTHER=other.test'
update
if [ "$(gets)" = 3 ]; then
	ok "a changed file: downloaded"
else
	bad "changed file: GET $(gets)"
fi

exit "$fail"
