#!/bin/sh
# Versions compared: a prerelease (-exp.N, _preN) is older than its release,
# by the real code of every entry point: the command line (version_newer of
# /usr/bin/mayhem, which calls mayhem.version), mayhem.version itself (the
# rpcd plugin) and the dashboard's own JS (components.js) when node is there.
#   UCODE=ucode tests/prerelease.sh
set -eu

ROOT="$(cd "$(dirname "$0")/.." && pwd)"
BIN="$ROOT/mayhem/files/usr/bin/mayhem"
JS="$ROOT/luci-app-mayhem/htdocs/luci-static/resources/mayhem/page/components.js"
UCODE="${UCODE:-ucode}"
T="$(mktemp -d)"
trap 'rm -rf "$T"' EXIT
fail=0

ok() { printf 'ok   %s\n' "$1"; }
bad() { printf 'FAIL %s\n' "$1"; fail=1; }

# ucode as the router has it: the modules of the package on its path
mkdir -p "$T/bin"
printf '#!/bin/sh\nexec %s -L "%s/mayhem/files/usr/share/ucode/*.uc" "$@"\n' "$UCODE" "$ROOT" > "$T/bin/ucode"
chmod +x "$T/bin/ucode"
sed -n '/^version_newer() {/,/^}/p' "$BIN" > "$T/cli.sh"

cli_newer() {
	# shellcheck disable=SC2016 # expanded by the inner shell
	PATH="$T/bin:$PATH" sh -c '. "$1"; version_newer "$2" "$3"' sh "$T/cli.sh" "$1" "$2"
}

uc_newer() {
	PATH="$T/bin:$PATH" ucode -e "import { version_newer } from 'mayhem.version'; exit(version_newer(ARGV[0], ARGV[1]) ? 0 : 1);" "$1" "$2"
}

# parseVersion() and newer() of components.js, as they are there
js_newer() {
	node - "$JS" "$1" "$2" <<'NODE'
const src = require('fs').readFileSync(process.argv[2], 'utf8');
const body = (name) => {
	const i = src.indexOf(`function ${name}(`);
	const j = src.indexOf('\n}\n', i);
	return src.slice(i, j + 3);
};
const newer = new Function(body('parseVersion') + body('newer') + 'return newer;')();
process.exit(newer(process.argv[3], process.argv[4]) ? 0 : 1);
NODE
}

ways="cli uc"
command -v node >/dev/null 2>&1 && ways="$ways js"

check_case() {
	for w in $ways; do
		if "${w}_newer" "$1" "$2" && ! "${w}_newer" "$2" "$1"; then
			ok "$w: $1 > $2"
		else
			bad "$w: $1 > $2"
		fi
	done
}

check_case "0.8.0" "0.8.0_pre1"
check_case "0.8.0" "0.8.0-exp.1"
check_case "0.8.0_pre2" "0.8.0_pre1"
check_case "0.8.0-exp.2" "0.8.0-exp.1"
check_case "0.8.1_pre1" "0.8.0"
check_case "1.0.0" "0.9.9"
check_case "1.0.0" "1.0.0-exp.10"
check_case "v0.27.2" "0.27.1"
check_case "0.27.10" "0.27.9"

# The same prerelease written both ways: neither is newer
for w in $ways; do
	if ! "${w}_newer" "0.8.0_pre1" "0.8.0-exp.1" && ! "${w}_newer" "0.8.0-exp.1" "0.8.0_pre1" && ! "${w}_newer" "0.27.1" "v0.27.1"; then
		ok "$w: 0.8.0_pre1 == 0.8.0-exp.1, 0.27.1 == v0.27.1"
	else
		bad "$w: equal versions"
	fi
done

exit "$fail"
