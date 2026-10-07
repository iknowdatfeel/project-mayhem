# Mayhem: shared constants for shell scripts.
# Keep in sync with /usr/share/ucode/mayhem/const.uc (tests/run.sh checks it).
# Paths can be overridden from the environment for off-device tests.

MAYHEM_VERSION="__MAYHEM_VERSION__"
MAYHEM_XRAY_VERSION="26.9.30"

MAYHEM_TPROXY_PORT=12701
MAYHEM_DNS_PORT=12753
MAYHEM_API_PORT=12780
MAYHEM_METRICS_PORT=12781
MAYHEM_HELPER_PORT=12782
MAYHEM_FWMARK=0x2000000
MAYHEM_RT_TABLE=109
MAYHEM_RULE_PRIO=109
MAYHEM_NFT_TABLE=mayhem
MAYHEM_RUN_DIR="${MAYHEM_RUN_DIR:-/var/run/mayhem}"
MAYHEM_SUBS_DIR="${MAYHEM_SUBS_DIR:-/etc/mayhem/subs}"

MAYHEM_XRAY_BIN="${MAYHEM_XRAY_BIN:-/usr/libexec/mayhem/xray}"
MAYHEM_LIB_DIR="${MAYHEM_LIB_DIR:-/usr/share/mayhem}"
MAYHEM_GEN="$MAYHEM_LIB_DIR/gen.uc"
MAYHEM_SUB="$MAYHEM_LIB_DIR/sub.uc"
MAYHEM_DNSMASQ_INIT="${MAYHEM_DNSMASQ_INIT:-/etc/init.d/dnsmasq}"
MAYHEM_DNSMASQ_FILE=mayhem.conf

# Services that intercept traffic the same way; Mayhem refuses to start next to them.
MAYHEM_CONFLICTS="podkop forkop passwall passwall2 homeproxy openclash nikki mihomo ssclash v2raya"
