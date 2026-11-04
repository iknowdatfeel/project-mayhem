package dnspolicy

import (
	"net/netip"
	"strings"
	"testing"
)

func TestNFTPriorityAndValidation(t *testing.T) {
	n := NFTInstaller{Config: Config{Interfaces: []string{"br-lan"}, BlockIP: []string{"192.0.2.0/24"}, DirectIP: []string{"192.0.2.0/24"}, DirectPorts: []string{"80", "100-200"}}}
	script, err := n.Script(Snapshot{Block6: []netip.Addr{netip.MustParseAddr("2001:db8::1")}})
	if err != nil {
		t.Fatal(err)
	}
	if strings.Index(script, "ip daddr @block4 drop") > strings.Index(script, "ip daddr @direct4 ct mark") {
		t.Fatal("Direct precedes Block")
	}
	if !strings.Contains(script, "type route hook output priority -151") || !strings.Contains(script, "type filter hook prerouting priority -151") {
		t.Fatal("missing router or LAN policy hook")
	}
	n.Config.DirectPorts = []string{"80; flush ruleset"}
	if _, err = n.Script(Snapshot{}); err == nil {
		t.Fatal("accepted injected port")
	}
	n.Config.DirectPorts = nil
	n.Config.BlockIP = []string{"1.2.3.4; flush ruleset"}
	if _, err = n.Script(Snapshot{}); err == nil {
		t.Fatal("accepted injected IP")
	}
}
