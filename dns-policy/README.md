# Native DNS policy

This component classifies DNS questions for Mayhem's Block and Direct sections.
It does not proxy application connections. Matching DNS names obtain real
addresses from the domestic DNS servers; an atomic nftables transaction installs
those addresses before the DNS reply is returned. Other names use the generated
Mayhem upstream routes, including Xray DNS for proxy names.

FakeDNS is disabled with an explicit configuration warning: native policy
requires real addresses. Proxy-domain addresses are marked `0x80000000` by the
resolver, so list mode still intercepts them without artificial IPs. DNS names
not matching a proxy rule are not marked merely because their DNS used Xray.

Supported matchers: `domain:`, `full:`, `keyword:`, Go `regexp:` and references
into Mayhem's trimmed GeoSite files, including attribute selection. Block wins
when a name or address matches both actions. Exact and suffix matching use maps;
keyword and regexp matching scan only their respective pattern lists.

## Packet path

The independently owned `inet mayhem_policy` table runs before Mayhem's existing
prerouting/output hooks. Block addresses are dropped. Direct addresses/ports set
packet mark `0x40000000`; Mayhem's normal interception skips that mark. Existing
Direct flows retain the decision in conntrack so DNS TTL expiration does not
redirect an established connection into Xray. A current Block address still
wins over an established Direct decision. Changes to Direct affect new flows;
existing sessions are not migrated to another route.

Xray and the resolver's upstream sockets use `0x1000000` to avoid interception.
The new service runs independently from Xray under procd. It owns its table,
restores still-valid DNS bindings after restart, re-evaluates their names under
the new policy, and expires individual bindings. Two names sharing an address
retain independent expiration times. Failure to install a policy produces a DNS
SERVFAIL rather than returning an address without enforcement.

DNS state is in `/var/run/mayhem/dns-policy.bindings.json` (RAM, mode 0600).
The DNS listener is loopback-only, UDP and TCP, on 12754. Upstream UDP responses
with TC fall back to TCP. Downstream UDP responses exceeding 512 bytes use TC,
so clients can retry over TCP. dnsmasq retains its OpenWrt cache configuration;
the resolver does not cache upstream replies. Cached answers retain the remaining
DNS lifetime of the bindings already installed before the original reply.
Mayhem flushes the dnsmasq cache on policy reload and upstream-route changes,
even when the loopback policy-listener address stays unchanged.
Zero-TTL replies retain TTL zero and use a five-second kernel admission window for the immediate connection.

## Configuration and lifecycle

`build.uc` exports `dns-policy.json`. The init script validates its rules before
using it as `dns-policy.running.json`; invalid rules name the section and cause.
GeoSite changes are watched by procd. `mayhem_dns_servers` writes the original
upstream routes into `dns-policy.upstreams`, ISP resolvers into `dns-policy.isp`,
and directs dnsmasq at the policy listener. These files also handle Xray restart
and the existing remote-DNS fallback without disabling native Block/Direct.

Native policy currently rejects reverse/unexpanded GeoIP explicitly.
The global domestic DNS list is independent of Xray. Section-specific DNS
settings retain their existing Xray DNS-only transport (including DoH/DoQ);
application Block/Direct traffic still bypasses Xray. Such custom DNS needs
a running Xray.
Excluded devices and configured local-network bypasses remain excluded.
An explicit Mayhem stop removes both the normal and policy tables.

The architecture-independent Mayhem package remains ucode. The Go engine is
built without CGO for the architectures already enumerated by `xray_asset`.
`mayhem dns-policy-install` installs the matching release ZIP after checking its
SHA-256 and that the binary starts. The release installer downloads and verifies the engine before replacing
packages, then calls this command with the local ZIP and its `.sha256` sidecar.
This stage does not need DNS after package upgrade scripts stop Mayhem.
Direct package installation must install this binary as well; validation will
otherwise report the missing executable. Building a new engine does not publish
or deploy it.

## Limits

A DNS-derived IP policy cannot distinguish different sites sharing the same IP:
Block wins for the whole address. DNS not observed by the router cannot populate
sets. Previously unknown addresses held in client caches are not inferred.
Addresses learned in policy DNS replies remain valid only for their DNS lifetime;
connections to unobserved aliases/hints require their own observable address
answer. This is not packet-level domain inspection or a guarantee against DNS
bypass. Protocols and deployments requiring a stronger guarantee need additional
measures.

## Local verification

```
cd dns-policy
go test -race ./...
go test -fuzz=FuzzDNSPacket -fuzztime=10s
GOOS=linux GOARCH=arm64 CGO_ENABLED=0 go build ./cmd/mayhem-dns
```

The unit and loopback tests use a fake nftables installer and do not touch the
host firewall. Testing the emitted nftables script and procd lifecycle requires
an isolated Linux/OpenWrt environment, not the user's router. Host tests are not
device verification.
