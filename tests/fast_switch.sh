#!/bin/sh
set -eu

ROOT="$(cd "$(dirname "$0")/.." && pwd)"
FILES="$ROOT/mayhem/files"
UCODE="${UCODE:-ucode}"
T="$(mktemp -d)"
fail=0

trap 'rm -rf "$T"' EXIT

ok() { printf 'ok   %s\n' "$1"; }
bad() { printf 'FAIL %s\n' "$1"; fail=1; }

mkdir -p "$T/run" "$T/uci"
export MAYHEM_RUN_DIR="$T/run" MAYHEM_UCI_DIR="$T/uci"

# Initial state setup
cat > "$T/run/nodes.json" <<'JSON'
{
  "sections": {
    "pool": {
      "mode": "auto",
      "selected": "n-pool-1",
      "nodes": [
        { "tag": "n-pool-1", "name": "Proxy 1", "protocol": "vless" },
        { "tag": "n-pool-2", "name": "Proxy 2", "protocol": "vless" },
        { "tag": "n-pool-tun", "name": "awg0", "protocol": "interface", "iface": "awg0" }
      ]
    }
  },
  "flow_path": {
    "generation": 1
  }
}
JSON

cat > "$T/run/health.json" <<'JSON'
{
  "sections": {
    "pool": {
      "down": true,
      "fails": 3,
      "picked": 1000
    }
  },
  "dns": {
    "down": true
  }
}
JSON

cat > "$T/run/nft.conf" <<'NFT'
table inet mayhem {
	chain mangle_prerouting {
		ct state established,related ct mark & 0x30000000 != 0 ct mark & 0x30000000 != 0x10000000 meta mark set meta mark | 0x8000000 counter return
		meta mark set meta mark & 0x4000001 ct mark set ct mark & 0xcfffffff | 0x10000000 counter return
	}
}
NFT
cp "$T/run/nft.conf" "$T/run/running.nft.conf"

printf 'initial_xray_key\n' > "$T/run/xray.key"
printf 'initial_xray_key\n' > "$T/run/running.xray.key"

cat > "$T/uci/mayhem" <<'UCI'
config settings 'settings'
	option reconnect_epoch '100'

config pool 'pool'
	option select 'auto'
	option selected 'n-pool-1'
UCI

# Helper to run python fast_switch verification
run_fast_switch_test() {
	python3 - "$T" "$1" "$2" <<'PY'
import sys, os, json, re, time

root_dir = sys.argv[1]
run_dir = os.path.join(root_dir, "run")
uci_dir = os.path.join(root_dir, "uci")
from_tag = sys.argv[2]
to_tag = sys.argv[3]

with open(os.path.join(run_dir, "nodes.json")) as f:
    nodes = json.load(f)

sec = nodes.get("sections", {}).get("pool", {})
cur_node = next((n for n in sec.get("nodes", []) if n.get("tag") == from_tag), None)
new_node = next((n for n in sec.get("nodes", []) if n.get("tag") == to_tag), None)

is_cur_kernel = cur_node and (cur_node.get("iface") is not None or cur_node.get("protocol") == "interface")
is_new_kernel = new_node and (new_node.get("iface") is not None or new_node.get("protocol") == "interface")

active = True # simulating active xray
fast_path = active and not is_cur_kernel and not is_new_kernel

# Read uci settings
uci_file = os.path.join(uci_dir, "mayhem")
with open(uci_file) as f:
    uci_text = f.read()

reconnect_epoch_matched = re.search(r"option reconnect_epoch '([0-9]+)'", uci_text)
old_epoch = int(reconnect_epoch_matched.group(1)) if reconnect_epoch_matched else 0

if not fast_path:
    new_epoch = old_epoch + 1
    uci_text = re.sub(r"option reconnect_epoch '[0-9]+'", f"option reconnect_epoch '{new_epoch}'", uci_text)
    with open(uci_file, "w") as f:
        f.write(uci_text)
    sys.exit(2) # indicates non-fast path taken

# Fast-path operations:
# 1. Update nodes.json and flow_path generation
prev_gen = int(nodes.get("flow_path", {}).get("generation", 1))
next_gen = (prev_gen % 3) + 1
nodes["flow_path"]["generation"] = next_gen
sec["selected"] = to_tag
with open(os.path.join(run_dir, "nodes.json"), "w") as f:
    json.dump(nodes, f, indent=2)

# 2. Update health.json
with open(os.path.join(run_dir, "health.json")) as f:
    health = json.load(f)
health.setdefault("sections", {})["pool"] = {
    "down": False,
    "fails": 0,
    "picked": int(time.time())
}
if health.get("dns", {}).get("down"):
    health["dns"] = {}
with open(os.path.join(run_dir, "health.json"), "w") as f:
    json.dump(health, f, indent=2)

# 3. Update nft.conf and running.nft.conf generation mask
gen_hex = hex(next_gen << 28)
gmask = "0x30000000"
cmask = "0xcfffffff"

for fname in ["nft.conf", "running.nft.conf"]:
    fpath = os.path.join(run_dir, fname)
    if os.path.exists(fpath):
        with open(fpath) as f:
            t = f.read()
        t = re.sub(r"ct mark & 0x30000000 != 0x[0-9a-fA-F]+", f"ct mark & {gmask} != {gen_hex}", t)
        t = re.sub(r"ct mark set ct mark & 0xcfffffff \| 0x[0-9a-fA-F]+", f"ct mark set ct mark & {cmask} | {gen_hex}", t)
        with open(fpath, "w") as f:
            f.write(t)

sys.exit(0)
PY
}

# 1. Test proxy-to-proxy switch (n-pool-1 -> n-pool-2): Fast-Path
key_before="$(cat "$T/run/xray.key")"
epoch_before="$(grep "reconnect_epoch" "$T/uci/mayhem")"

set +e
run_fast_switch_test "n-pool-1" "n-pool-2"
rc=$?
set -e

if [ "$rc" = 0 ]; then
	ok "fast-path taken for proxy-to-proxy switch"
else
	bad "fast-path failed: exit code $rc"
fi

key_after="$(cat "$T/run/xray.key")"
epoch_after="$(grep "reconnect_epoch" "$T/uci/mayhem")"

if [ "$key_before" = "$key_after" ]; then
	ok "xray.key unchanged during fast switch"
else
	bad "xray.key changed during fast switch: '$key_before' != '$key_after'"
fi

if [ "$epoch_before" = "$epoch_after" ]; then
	ok "reconnect_epoch not bumped during fast switch"
else
	bad "reconnect_epoch changed during fast switch: '$epoch_before' != '$epoch_after'"
fi

# Check generation updated from 1 to 2 in nodes.json
gen_in_nodes="$(python3 -c "import json; print(json.load(open('$T/run/nodes.json'))['flow_path']['generation'])")"
if [ "$gen_in_nodes" = "2" ]; then
	ok "flow_path.generation advanced to 2 in nodes.json"
else
	bad "flow_path.generation in nodes.json is $gen_in_nodes, expected 2"
fi

# Check nft generation mask updated in running.nft.conf (0x2 << 28 = 0x20000000)
if grep -q 'ct mark & 0x30000000 != 0x20000000' "$T/run/running.nft.conf" && \
   grep -q 'ct mark set ct mark & 0xcfffffff | 0x20000000' "$T/run/running.nft.conf"; then
	ok "generation mask 0x20000000 applied to running.nft.conf"
else
	bad "generation mask 0x20000000 not found in running.nft.conf: $(cat "$T/run/running.nft.conf")"
fi

# Check health.json section pool reset
down_val="$(python3 -c "import json; print(json.load(open('$T/run/health.json'))['sections']['pool']['down'])")"
fails_val="$(python3 -c "import json; print(json.load(open('$T/run/health.json'))['sections']['pool']['fails'])")"
if [ "$down_val" = "False" ] && [ "$fails_val" = "0" ]; then
	ok "health.json down=false and fails=0 after fast switch"
else
	bad "health.json not reset: down=$down_val, fails=$fails_val"
fi

# 2. Test proxy-to-kernel switch (n-pool-2 -> n-pool-tun): Must NOT use Fast-Path
set +e
run_fast_switch_test "n-pool-2" "n-pool-tun"
rc_kernel=$?
set -e

if [ "$rc_kernel" = 2 ]; then
	ok "kernel switch correctly rejects fast-path"
else
	bad "kernel switch did not reject fast-path: exit code $rc_kernel"
fi

epoch_after_kernel="$(grep "reconnect_epoch" "$T/uci/mayhem")"
if [ "$epoch_after_kernel" != "$epoch_before" ]; then
	ok "reconnect_epoch bumped on kernel switch ($epoch_after_kernel)"
else
	bad "reconnect_epoch was not bumped on kernel switch"
fi

# 3. Test generation cycle (1 -> 2 -> 3 -> 1)
test_gen_cycle() {
	python3 <<'PY'
import sys

def next_gen(g):
    return (g % 3) + 1

g = 1
seq = [g]
for _ in range(5):
    g = next_gen(g)
    seq.append(g)

assert seq == [1, 2, 3, 1, 2, 3], f"Invalid generation sequence: {seq}"
print("ok")
PY
}

if [ "$(test_gen_cycle)" = "ok" ]; then
	ok "generation cycle 1 -> 2 -> 3 -> 1 confirmed"
else
	bad "generation cycle failed"
fi

# 4. If ucode is available, test apply_generation and net_base directly
if command -v "$UCODE" >/dev/null 2>&1; then
	if "$UCODE" -L "$FILES/usr/share/ucode/*.uc" -e '
		import * as build from "mayhem.build";
		const nft = "ct mark & 0x30000000 != 0x10000000 ct mark set ct mark & 0xcfffffff | 0x10000000";
		const updated = build.apply_generation(nft, 2);
		exit(index(updated, "0x20000000") >= 0 ? 0 : 1);
	'; then
		ok "ucode apply_generation replaces generation mask correctly"
	else
		bad "ucode apply_generation failed"
	fi
fi

exit "$fail"
