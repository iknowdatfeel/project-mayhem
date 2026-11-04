package dnspolicy

import (
	"errors"
	"net/netip"
	"testing"
	"time"
)

func TestDomainPolicy(t *testing.T) {
	m, err := Compile([]Rule{
		{Section: "direct", Action: Direct, Domains: []string{"domain:windowsupdate.com", "full:exact.test", "keyword:bank"}},
		{Section: "block", Action: Block, Domains: []string{"regexp:^download\\.windowsupdate\\.com$", "domain:ads.test"}},
	})
	if err != nil {
		t.Fatal(err)
	}
	for name, want := range map[string]Action{
		"download.windowsupdate.com":  Block,
		"DOWNLOAD.WINDOWSUPDATE.COM.": Block,
		"windowsupdate.com":           Direct,
		"otherwindowsupdate.com":      "",
		"a.ads.test":                  Block,
		"notads.test":                 "",
		"exact.test":                  Direct,
		"sub.exact.test":              "",
		"mybank.test":                 Direct,
	} {
		if got := m.Match(name).Action; got != want {
			t.Errorf("%q: got %q, want %q", name, got, want)
		}
	}
}

func TestRejectInvalidRules(t *testing.T) {
	for _, rule := range []string{"regexp:[", "geosite:ads", "ext:geo.dat:ads", "domain:", "full:a..test"} {
		if _, err := Compile([]Rule{{Section: "block", Action: Block, Domains: []string{rule}}}); err == nil {
			t.Errorf("accepted invalid or unexpanded rule %q", rule)
		}
	}
}

type fakeInstaller struct {
	snapshot Snapshot
	fail     bool
}

func (f *fakeInstaller) Replace(s Snapshot) error {
	if f.fail {
		return errors.New("nft transaction failed")
	}
	f.snapshot = s
	return nil
}

func TestSharedAddressExpirationAndRollback(t *testing.T) {
	f := &fakeInstaller{}
	s := NewStore(f)
	now := time.Unix(1000, 0)
	addr := netip.MustParseAddr("203.0.113.10")
	if err := s.Commit(now, []Binding{
		{Name: "allowed.test", Address: addr, Action: Direct, Expires: now.Add(time.Minute)},
		{Name: "blocked.test", Address: addr, Action: Block, Expires: now.Add(10 * time.Second)},
	}); err != nil {
		t.Fatal(err)
	}
	if len(f.snapshot.Block4) != 1 || len(f.snapshot.Direct4) != 0 {
		t.Fatal("shared address did not choose Block")
	}
	if err := s.Commit(now.Add(11*time.Second), nil); err != nil {
		t.Fatal(err)
	}
	if len(f.snapshot.Block4) != 0 || len(f.snapshot.Direct4) != 1 {
		t.Fatal("expiry erased the other domain binding")
	}
	f.fail = true
	if err := s.Commit(now.Add(12*time.Second), []Binding{{Name: "new.test", Address: addr, Action: Block, Expires: now.Add(time.Minute)}}); err == nil {
		t.Fatal("kernel error was ignored")
	}
	f.fail = false
	if err := s.Commit(now.Add(13*time.Second), nil); err != nil {
		t.Fatal(err)
	}
	if len(f.snapshot.Block4) != 0 || len(f.snapshot.Direct4) != 1 {
		t.Fatal("failed transaction changed stored policy")
	}
	if err := s.Commit(now.Add(61*time.Second), nil); err != nil {
		t.Fatal(err)
	}
	if len(f.snapshot.Block4)+len(f.snapshot.Direct4) != 0 {
		t.Fatal("expired address retained")
	}
}

func TestIPv6AndMappedIPv4(t *testing.T) {
	f := &fakeInstaller{}
	s := NewStore(f)
	now := time.Unix(1000, 0)
	if err := s.Commit(now, []Binding{
		{Name: "v6.test", Address: netip.MustParseAddr("2001:db8::1"), Action: Block, Expires: now.Add(time.Minute)},
		{Name: "v4.test", Address: netip.MustParseAddr("::ffff:203.0.113.10"), Action: Direct, Expires: now.Add(time.Minute)},
	}); err != nil {
		t.Fatal(err)
	}
	if len(f.snapshot.Block6) != 1 || len(f.snapshot.Direct4) != 1 || len(f.snapshot.Direct6) != 0 {
		t.Fatal("wrong address family")
	}
}
