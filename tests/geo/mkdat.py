#!/usr/bin/env python3
"""Writes small geosite.dat and geoip.dat files for the tests.

    mkdat.py OUTDIR

The format is the v2fly protobuf (GeoSiteList / GeoIPList), encoded by hand
so the tests need no protobuf library.
"""

import ipaddress
import os
import sys


def varint(n):
    out = bytearray()
    while n >= 0x80:
        out.append((n & 0x7F) | 0x80)
        n >>= 7
    out.append(n)
    return bytes(out)


def field(num, wire, payload):
    tag = varint(num << 3 | wire)
    if wire == 0:
        return tag + varint(payload)
    return tag + varint(len(payload)) + payload


TYPES = {'keyword': 0, 'regexp': 1, 'domain': 2, 'full': 3}


def geosite(categories):
    out = b''
    for code, rules in categories:
        entry = field(1, 2, code.encode())
        for rule in rules:
            kind, value = rule.split(':', 1)
            dom = field(1, 0, TYPES[kind]) + field(2, 2, value.encode()) if TYPES[kind] else field(2, 2, value.encode())
            entry += field(2, 2, dom)
        out += field(1, 2, entry)
    return out


def geoip(categories):
    out = b''
    for code, nets in categories:
        entry = field(1, 2, code.encode())
        for net in nets:
            n = ipaddress.ip_network(net)
            entry += field(2, 2, field(1, 2, n.network_address.packed) + field(2, 0, n.prefixlen))
        out += field(1, 2, entry)
    return out


def main():
    outdir = sys.argv[1]
    os.makedirs(outdir, exist_ok=True)

    heavy = ['domain:h%d.heavy.test' % i for i in range(50001)]

    sites = [
        ('YOUTUBE', ['domain:youtube.test', 'full:www.yt.test', 'keyword:tubekw', 'regexp:^re[0-9]+\\.test$']),
        ('GOV', ['domain:gosuslugi.test']),
        ('HEAVY', heavy),
        ('EMPTY', []),
    ]

    ips = [
        ('RU', ['45.0.0.6/32', '2001:db8:1::/48']),
        ('TELEGRAM', ['45.0.0.7/32', '91.108.4.0/22']),
        ('PRIVATE', ['10.0.0.0/8', '192.168.0.0/16']),
    ]

    with open(os.path.join(outdir, 'geosite.dat'), 'wb') as f:
        f.write(geosite(sites))

    with open(os.path.join(outdir, 'geoip.dat'), 'wb') as f:
        f.write(geoip(ips))


if __name__ == '__main__':
    main()
