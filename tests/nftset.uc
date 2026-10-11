// dnsmasq_nftset() against real `dnsmasq --version` output: OpenWrt's plain
// dnsmasq says "no-nftset", dnsmasq-full says "nftset". Exits 1 on a mistake.
//   ucode tests/nftset.uc
'use strict';

import { dnsmasq_nftset } from 'mayhem.rules';

const plain = 'Dnsmasq version 2.90  Copyright (c) 2000-2024 Simon Kelley\n' +
	'Compile time options: IPv6 GNU-getopt no-DBus UBus no-i18n no-IDN DHCP no-DHCPv6 no-Lua TFTP no-conntrack no-ipset no-nftset no-auth no-cryptohash no-DNSSEC no-ID loop-detect inotify dumpfile\n';
const full = 'Dnsmasq version 2.90  Copyright (c) 2000-2024 Simon Kelley\n' +
	'Compile time options: IPv6 GNU-getopt no-DBus UBus no-i18n IDN2 DHCP DHCPv6 no-Lua TFTP conntrack no-ipset nftset auth cryptohash DNSSEC no-ID loop-detect inotify dumpfile\n';

exit((!dnsmasq_nftset(plain) && dnsmasq_nftset(full) && !dnsmasq_nftset(null) && !dnsmasq_nftset('')) ? 0 : 1);
