// Mayhem: shared constants. Keep in sync with /usr/share/mayhem/const.sh
// (tests/run.sh checks that both files agree). Paths can be overridden from
// the environment for off-device tests.

export const UCI_DIR = getenv('MAYHEM_UCI_DIR');

'use strict';

export const TPROXY_PORT = 12701;
export const DNS_PORT = 12753;
export const API_PORT = 12780;
export const METRICS_PORT = 12781;
export const HELPER_PORT = 12782;
export const HELPER_PASS = 'mayhem';
export const FWMARK = 0x2000000;
export const RT_TABLE = 109;
// Tunnel sections in kernel mode: mark TUN_MARK | n (n = 1..TUN_MAX) selects
// routing table TUN_TABLE + n; their ip rules go in at priority TUN_RULE_PRIO.
export const TUN_MARK = 0x4000000;
export const TUN_MASK = 0x40000ff;
export const TUN_TABLE = 110;
export const TUN_MAX = 32;
export const TUN_RULE_PRIO = 108;
export const NFT_TABLE = 'mayhem';
export const RUN_DIR = getenv('MAYHEM_RUN_DIR') ?? '/var/run/mayhem';
export const SUBS_DIR = getenv('MAYHEM_SUBS_DIR') ?? '/etc/mayhem/subs';
export const GEO_DIR = getenv('MAYHEM_GEO_DIR') ?? '/etc/mayhem/geo';
export const LISTS_DIR = getenv('MAYHEM_LISTS_DIR') ?? '/etc/mayhem/lists';
export const MAX_NODES = 200;
export const FAKEDNS_POOL = '198.18.0.0/15';
export const FAKEDNS_POOL_SIZE = 8192;

export const DEFAULT_PROBE_URL = 'https://www.gstatic.com/generate_204';
export const DEFAULT_PROBE_INTERVAL = '3m';

export const DEFAULT_REMOTE_DNS = [ 'https://1.1.1.1/dns-query', 'https://8.8.8.8/dns-query' ];
export const FALLBACK_DOMESTIC_DNS = [ '77.88.8.8', '77.88.8.1' ];

export const LOCAL4 = [
	'0.0.0.0/8', '10.0.0.0/8', '100.64.0.0/10', '127.0.0.0/8', '169.254.0.0/16',
	'172.16.0.0/12', '192.0.0.0/24', '192.0.2.0/24', '192.168.0.0/16',
	'198.51.100.0/24', '203.0.113.0/24', '224.0.0.0/4', '240.0.0.0/4'
];

export const LOCAL6 = [
	'::/127', '64:ff9b:1::/48', '100::/64', '2001:db8::/32',
	'fc00::/7', 'fe80::/10', 'ff00::/8'
];
