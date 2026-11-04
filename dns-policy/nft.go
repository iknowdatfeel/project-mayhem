package dnspolicy

import (
	"context"
	"fmt"
	"net/netip"
	"os/exec"
	"sort"
	"strconv"
	"strings"
	"time"
)

const DirectMark = "0x40000000"
const ProxyMark = "0x80000000"

type Config struct {
	SectionDNS    map[string][]string `json:"section_dns"`
	Listen        string              `json:"listen"`
	Rules         []Rule              `json:"rules"`
	Domestic      []string            `json:"domestic"`
	Interfaces    []string            `json:"interfaces"`
	Exempt        []string            `json:"exempt"`
	Bypass4       []string            `json:"bypass4"`
	Bypass6       []string            `json:"bypass6"`
	BypassMAC     []string            `json:"bypass_mac"`
	BlockIP       []string            `json:"block_ip"`
	DirectIP      []string            `json:"direct_ip"`
	DirectPorts   []string            `json:"direct_ports"`
	UpstreamsFile string              `json:"upstreams_file"`
	ISPFile       string              `json:"isp_file"`
}

type NFTInstaller struct {
	Config     Config
	lastScript string
}

func prefixes(xs []string, ipv4 bool) ([]string, error) {
	out := []string{}
	for _, s := range xs {
		p, e := netip.ParsePrefix(s)
		if e != nil {
			a, e2 := netip.ParseAddr(s)
			if e2 != nil {
				return nil, fmt.Errorf("invalid policy prefix %q", s)
			}
			p = netip.PrefixFrom(a, a.BitLen())
		}
		if p.Addr().Zone() != "" {
			return nil, fmt.Errorf("scoped policy address is unsupported")
		}
		if p.Addr().Is4() == ipv4 {
			out = append(out, p.Masked().String())
		}
	}
	return out, nil
}
func setText(name, kind string, addresses []string) string {
	sort.Strings(addresses)
	elements := ""
	if len(addresses) > 0 {
		elements = " elements = { " + strings.Join(addresses, ", ") + " };"
	}
	return " set " + name + " { type " + kind + "; flags interval; auto-merge;" + elements + " }\n"
}
func (i *NFTInstaller) Script(s Snapshot) (string, error) {
	c := i.Config
	var out strings.Builder
	out.WriteString("table inet mayhem_policy\ndelete table inet mayhem_policy\ntable inet mayhem_policy {\n")
	for _, spec := range []struct {
		name    string
		static  []string
		dynamic []netip.Addr
		v4      bool
	}{
		{"block4", c.BlockIP, s.Block4, true}, {"block6", c.BlockIP, s.Block6, false},
		{"direct4", c.DirectIP, s.Direct4, true}, {"direct6", c.DirectIP, s.Direct6, false},
		{"proxy4", nil, s.Proxy4, true}, {"proxy6", nil, s.Proxy6, false},
		{"exempt4", c.Exempt, nil, true}, {"exempt6", c.Exempt, nil, false},
		{"bypass4", c.Bypass4, nil, true}, {"bypass6", c.Bypass6, nil, false},
	} {
		values, err := prefixes(spec.static, spec.v4)
		if err != nil {
			return "", err
		}
		for _, a := range spec.dynamic {
			if !a.IsValid() || a.Is4() != spec.v4 {
				return "", fmt.Errorf("invalid policy address family")
			}
			values = append(values, a.String())
		}
		kind := "ipv6_addr"
		if spec.v4 {
			kind = "ipv4_addr"
		}
		out.WriteString(setText(spec.name, kind, values))
	}
	ifaces := []string{}
	for _, name := range c.Interfaces {
		if len(name) < 1 || len(name) > 15 || strings.IndexAny(name, "\x00\n\r") >= 0 {
			return "", fmt.Errorf("invalid policy interface")
		}
		ifaces = append(ifaces, strconv.Quote(name))
	}
	if len(ifaces) == 0 {
		return "", fmt.Errorf("no DNS policy LAN interfaces")
	}
	ports := []string{}
	for _, s := range c.DirectPorts {
		lo, hi, rangePort := strings.Cut(s, "-")
		a, e := strconv.Atoi(lo)
		if e != nil || a < 1 || a > 65535 {
			return "", fmt.Errorf("invalid Direct port %q", s)
		}
		if rangePort {
			b, e := strconv.Atoi(hi)
			if e != nil || b < a || b > 65535 {
				return "", fmt.Errorf("invalid Direct port %q", s)
			}
		}
		ports = append(ports, s)
	}
	// The original bypassed devices must remain outside Mayhem's policy.
	macs := []string{}
	for _, m := range c.BypassMAC {
		if len(m) != 17 {
			return "", fmt.Errorf("invalid bypass MAC")
		}
		for p, ch := range m {
			if p%3 == 2 {
				if ch != ':' {
					return "", fmt.Errorf("invalid bypass MAC")
				}
			} else if !strings.ContainsRune("0123456789abcdef", ch) {
				return "", fmt.Errorf("invalid bypass MAC")
			}
		}
		macs = append(macs, m)
	}
	out.WriteString(" chain decide {\n ip daddr @exempt4 return\n ip6 daddr @exempt6 return\n ip daddr @block4 drop\n ip6 daddr @block6 drop\n ct state established,related ct mark & " + DirectMark + " != 0 meta mark set meta mark | " + DirectMark + " return\n ip daddr @direct4 ct mark set ct mark | " + DirectMark + " meta mark set meta mark | " + DirectMark + " return\n ip6 daddr @direct6 ct mark set ct mark | " + DirectMark + " meta mark set meta mark | " + DirectMark + " return\n")
	if len(ports) > 0 {
		out.WriteString(" meta l4proto { tcp, udp } th dport { " + strings.Join(ports, ", ") + " } ct mark set ct mark | " + DirectMark + " meta mark set meta mark | " + DirectMark + " return\n")
	}
	out.WriteString(" ip daddr @proxy4 meta mark set meta mark | " + ProxyMark + " return\n ip6 daddr @proxy6 meta mark set meta mark | " + ProxyMark + " return\n")
	out.WriteString(" }\n chain prerouting {\n type filter hook prerouting priority -151; policy accept;\n iifname != { " + strings.Join(ifaces, ", ") + " } return\n ip saddr @bypass4 return\n ip6 saddr @bypass6 return\n")
	if len(macs) > 0 {
		out.WriteString(" ether saddr { " + strings.Join(macs, ", ") + " } return\n")
	}
	out.WriteString(" jump decide\n }\n chain output {\n type route hook output priority -151; policy accept;\n meta mark & 0x1000000 == 0x1000000 return\n fib daddr type { local, broadcast, multicast } return\n jump decide\n }\n}\n")
	return out.String(), nil
}
func (i *NFTInstaller) Replace(s Snapshot) error {
	script, err := i.Script(s)
	if err != nil {
		return err
	}
	if script == i.lastScript {
		return nil
	}
	ctx, cancel := context.WithTimeout(context.Background(), 5*time.Second)
	defer cancel()
	cmd := exec.CommandContext(ctx, "nft", "-f", "-")
	cmd.Stdin = strings.NewReader(script)
	if out, e := cmd.CombinedOutput(); e != nil {
		return fmt.Errorf("apply DNS policy nftables: %w: %s", e, strings.TrimSpace(string(out)))
	}
	i.lastScript = script
	return nil
}
