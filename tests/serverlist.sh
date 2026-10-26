#!/bin/sh
# One server list: keys, tunnels and every subscription are in it; the main
# section is always the list. A subscription's rule (the fastest of its
# servers, its chain, one chosen by hand) counts where the list's chain names
# it; fallback.uc moves the chain along with stand-ins for curl and xray; an
# older configuration (a subscription as the main section) is carried over.
#   UCODE=/opt/ucode-24.10/ucode tests/serverlist.sh

set -u

ROOT="$(cd "$(dirname "$0")/.." && pwd)"
FILES="$ROOT/mayhem/files"
UCODE="${UCODE:-ucode}"
T="$(mktemp -d)"
fail=0

uc() { "$UCODE" -L "$FILES/usr/share/ucode/*.uc" "$@"; }
ok() { printf 'ok   %s\n' "$1"; }
bad() {
	printf 'FAIL %s\n' "$1"
	fail=1
	if [ -n "${GITHUB_ACTIONS:-}" ]; then
		printf '::error title=%s::%s\n' "$(basename "$0")" "$1"
	fi
}

mkdir -p "$T/subs"
cat > "$T/subs/mysub.json" <<'JSON'
{ "nodes": [
  { "name": "A", "link": "ss://YWVzLTI1Ni1nY206cHc@1.2.3.4:8388#A" },
  { "name": "B (x).y", "link": "ss://YWVzLTI1Ni1nY206cHc@1.2.3.5:8388#B" },
  { "name": "C", "link": "ss://YWVzLTI1Ni1nY206cHc@1.2.3.6:8388#C" } ] }
JSON

# config DIR SUB-OPTIONS POOL-OPTIONS [SETTINGS]
config() {
	mkdir -p "$1"
	cat > "$1/mayhem" <<CFG
config settings 'settings'
	option enabled '1'
	option mode 'global'
	list interface 'br-lan'
${4:-}
config dns 'dns'
	list remote 'https://1.1.1.1/dns-query'

config subscription 'mysub'
	option url 'http://example.invalid/sub'
$2
config pool 'pool'
	list link 'ss://YWVzLTI1Ni1nY206cHc@1.2.3.10:8388#K1'
	list link 'ss://YWVzLTI1Ni1nY206cHc@1.2.3.11:8388#K2'
$3
CFG
}

gen() {
	MAYHEM_UCI_DIR="$1" MAYHEM_SUBS_DIR="$T/subs" MAYHEM_RUN_DIR="$2" uc "$FILES/usr/share/mayhem/gen.uc" --out "$2" 2>&1
}

# What the list chose, in names: "mode|chain|units|items|subs".
show() {
	uc -e "
		const n = json(require('fs').readfile('$1/nodes.json'));
		const p = n.sections.pool;
		const name = (t) => filter(p.nodes, (x) => x.tag == t)[0]?.name ?? '?';
		const subs = map(sort(keys(p.subs ?? {})), (k) => k + ':' + p.subs[k].mode +
			(p.subs[k].selected ? '=' + name(p.subs[k].selected) : '') +
			(p.subs[k].chain ? '=' + join('>', map(p.subs[k].chain, name)) : ''));
		const other = filter(keys(n.sections), (k) => k != 'pool');
		print(join('|', [ n.default_section, length(p.nodes), p.mode,
			join('>', map(p.chain ?? [], name)),
			join(' ', map(p.units ?? [], (u) => '[' + join(',', map(u, name)) + ']')),
			join(' ', map(p.items ?? [], (i) => i.sub ? '@' + i.sub + ':' + i.rule : name(i.tag))),
			join(' ', subs), join(',', other) ]));
	"
}

check() {
	what="$1" dir="$2" want="$3"

	if ! out="$(gen "$dir" "$dir.run")"; then
		bad "$what: generator failed: $out"
	elif [ "$(show "$dir.run")" = "$want" ]; then
		ok "$what"
	else
		bad "$what: got '$(show "$dir.run")', expected '$want'"
	fi
}

# 1. A subscription with a rule of its own stays in the list (no section of
# its own), the list is the main section.
config "$T/u1" "	option select 'manual'
	option selected 'C'" "	option select 'auto'"
check "every subscription is in the list, the list is the main section" "$T/u1" \
	"pool|5|auto||||mysub:manual=C|"

# 2. The chain names the subscription: with "the fastest" it is one unit of
# all its servers, then a key.
config "$T/u2" "" "	option select 'fallback'
	list chain '@mysub'
	list chain 'K2'"
check "chain: a subscription by its fastest server, then a key" "$T/u2" \
	"pool|5|fallback|A>B (x).y>C>K2|[A,B (x).y,C] [K2]|@mysub:auto K2|mysub:auto|"

# 3. The subscription's server chosen by hand.
config "$T/u3" "	option select 'manual'
	option selected 'B (x).y'" "	option select 'fallback'
	list chain 'K1'
	list chain '@mysub'"
check "chain: a key, then the server chosen in the subscription" "$T/u3" \
	"pool|5|fallback|K1>B (x).y||K1 @mysub:manual|mysub:manual=B (x).y|"

# 4. The subscription's own chain, and a single server of a subscription
# named with its subscription.
config "$T/u4" "	option select 'fallback'
	list chain 'C'
	list chain 'A'" "	option select 'fallback'
	list chain '@mysub'
	list chain 'mysub	B (x).y'"
check "chain: the subscription's own chain, then one of its servers by name" "$T/u4" \
	"pool|5|fallback|C>A>B (x).y||@mysub:fallback B (x).y|mysub:fallback=C>A|"

# 5. An older "chosen by hand" of the list is a pinned server now.
config "$T/u5" "" "	option select 'manual'
	option selected 'K2'"
if ! out="$(gen "$T/u5" "$T/u5.run")"; then
	bad "older manual choice: $out"
elif uc -e "
	const p = json(require('fs').readfile('$T/u5.run/nodes.json')).sections.pool;
	exit(p.mode == 'auto' && filter(p.nodes, (n) => n.tag == p.override)[0]?.name == 'K2' ? 0 : 1);
"; then
	ok "an older manual choice of the list is a pinned server"
else
	bad "older manual choice: $(show "$T/u5.run")"
fi

# 6. Migration: the subscription that was the main section becomes the
# list's chain; default_section is kept (unread) for going back.
config "$T/u6" "	option select 'auto'
	option override 'A'" "	option select 'manual'
	option selected 'K1'" "	option default_section 'sub_mysub'"
if ! out="$(MAYHEM_UCI_DIR="$T/u6" MAYHEM_SUBS_DIR="$T/subs" uc "$FILES/usr/share/mayhem/migrate.uc" 2>&1)"; then
	bad "migration: $out"
else
	res="$(uc -e "
		const c = require('uci').cursor('$T/u6');
		c.load('mayhem');
		print(join(',', [ c.get('mayhem', 'pool', 'select'), join(';', c.get('mayhem', 'pool', 'chain') ?? []),
			c.get('mayhem', 'pool', 'override') ?? '-', c.get('mayhem', 'mysub', 'override') ?? '-',
			c.get('mayhem', 'settings', 'default_section'), c.get('mayhem', 'pool', 'v') ]));
	")"
	if [ "$res" = 'fallback,@mysub,-,-,sub_mysub,2' ]; then
		ok "migration: the main subscription becomes the list's chain"
	else
		bad "migration: got '$res'"
	fi
fi

# 7. fallback.uc on the chain of test 2: the fastest working server of the
# subscription, another one of it when that one goes down, the key when the
# whole subscription is down, back to the subscription when it works.
mkdir -p "$T/bin"
cat > "$T/bin/curl" <<'EOF'
#!/bin/sh
user="" url=""
while [ $# -gt 0 ]; do
	case "$1" in
		-x) user="${2#socks5h://}"; user="${user%%:*}"; shift ;;
		-o|-m|-w|-H) shift ;;
		-*) ;;
		*) url="$1" ;;
	esac
	shift
done
case "$url" in
	*/debug/vars) printf '{"observatory":%s}' "$(cat "$STUB/obs.json" 2>/dev/null || echo '{}')"; exit 0 ;;
esac
if grep -qx "$user" "$STUB/dead" 2>/dev/null; then printf 000; else printf 204; fi
EOF
# shellcheck disable=SC2016
printf '#!/bin/sh\necho "$*" >> "$STUB/xray.log"\n' > "$T/bin/xray"
printf '#!/bin/sh\nexit 0\n' > "$T/bin/logger"
chmod +x "$T/bin/"*

R="$T/u2.run"
: > "$R/active"
tag() { uc -e "print(filter(json(require('fs').readfile('$R/nodes.json')).sections.pool.nodes, (n) => n.name == '$1')[0].tag)"; }
A="$(tag A)" B="$(tag 'B (x).y')" C="$(tag C)" K2="$(tag K2)"
name() {
	uc -e "
		const p = json(require('fs').readfile('$R/nodes.json')).sections.pool;
		print(filter(p.nodes, (n) => n.tag == p.selected)[0]?.name);
	"
}
obs() {
	printf '{"%s":{"alive":%s,"delay":%s},"%s":{"alive":%s,"delay":%s},"%s":{"alive":%s,"delay":%s},"%s":{"alive":true,"delay":200}}' \
		"$A" "$1" 300 "$B" "$2" 100 "$C" "$3" 150 "$K2" > "$T/obs.json"
}
fb() { PATH="$T/bin:$PATH" STUB="$T" MAYHEM_RUN_DIR="$R" MAYHEM_XRAY_BIN="$T/bin/xray" uc "$FILES/usr/share/mayhem/fallback.uc"; }

: > "$T/dead"
obs true true false
fb
step1="$(name)"
obs true false false
echo "$B" > "$T/dead"
fb
step2="$(name)"
obs false false false
printf '%s\n%s\n%s\n' "$A" "$B" "$C" > "$T/dead"
fb; fb
step3="$(name)"
obs true false false
: > "$T/dead"
fb
step4="$(name)"

if [ "$step1|$step2|$step3|$step4" = "B (x).y|A|K2|A" ]; then
	ok "fallback.uc: fastest of the subscription, the next of it, the key, back"
else
	bad "fallback.uc: got $step1|$step2|$step3|$step4, expected B (x).y|A|K2|A"
fi

# 8. The rpcd methods: a click from the chain, the chain's window.
mkdir -p "$T/u8"
: > "$T/u8/mayhem"
if out="$(MAYHEM_UCI_DIR="$T/u8" MAYHEM_RUN_DIR="$T/run8" MAYHEM_LIB_DIR="$T/none" \
	uc "$ROOT/tests/serverlist.uc" "$ROOT/luci-app-mayhem/root/usr/share/rpcd/ucode/luci.mayhem" 2>&1)"; then
	ok "rpcd: a server clicked in the chain is chosen by hand; the chain saved with its rules"
else
	bad "rpcd methods of the server list: $out"
fi

rm -rf "$T"
exit "$fail"
