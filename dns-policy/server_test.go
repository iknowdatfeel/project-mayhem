package dnspolicy

import (
	"encoding/binary"
	"net"
	"net/netip"
	"os"
	"path/filepath"
	"testing"
	"time"
)

func TestServerInstallsBeforeAnswer(t *testing.T) {
	listener, err := net.ListenPacket("udp", "127.0.0.1:0")
	if err != nil {
		t.Fatal(err)
	}
	defer listener.Close()
	done := make(chan struct{})
	go func() {
		defer close(done)
		buf := make([]byte, 4096)
		n, peer, e := listener.ReadFrom(buf)
		if e != nil {
			return
		}
		answer := append([]byte(nil), buf[:n]...)
		answer[2] = 0x81
		answer[3] = 0x80
		answer[7] = 1
		answer = append(answer, rrWire([]byte{0xc0, 12}, 1, 60, []byte{203, 0, 113, 10})...)
		listener.WriteTo(answer, peer)
	}()
	m, e := Compile([]Rule{{Section: "block", Action: Block, Domains: []string{"domain:windowsupdate.com"}}})
	if e != nil {
		t.Fatal(e)
	}
	f := &fakeInstaller{}
	server := Server{Matcher: m, Store: NewStore(f), Domestic: []string{listener.LocalAddr().String()}}
	q := queryWire("download.windowsupdate.com")
	answer, e := server.Handle(q)
	if e != nil {
		t.Fatal(e)
	}
	if len(f.snapshot.Block4) != 1 {
		t.Fatal("DNS answer returned before installing Block")
	}
	if len(answer) < 12 || binary.BigEndian.Uint16(answer) != binary.BigEndian.Uint16(q) {
		t.Fatal("DNS transaction ID was not restored")
	}
	<-done
}
func TestUpstreamRoutes(t *testing.T) {
	path := filepath.Join(t.TempDir(), "upstreams")
	if err := os.WriteFile(path, []byte("server=9.9.9.9\nserver=/example.com/127.0.0.1#12753\nserver=/sub.example.com/8.8.8.8\n"), 0600); err != nil {
		t.Fatal(err)
	}
	for name, want := range map[string]string{"other.test": "9.9.9.9:53", "www.example.com": "127.0.0.1:12753", "x.sub.example.com": "8.8.8.8:53"} {
		got := serverLines(path, name)
		if len(got) != 1 || got[0] != want {
			t.Errorf("%s: %v != %s", name, got, want)
		}
	}
}
func TestRestoreReclassifiesPolicy(t *testing.T) {
	f := &fakeInstaller{}
	s := NewStore(f)
	now := time.Now()
	path := filepath.Join(t.TempDir(), "state")
	bs := []Binding{{Name: "a.test", Address: netip.MustParseAddr("203.0.113.10"), Action: Direct, Expires: now.Add(time.Minute)}}
	if e := s.Commit(now, bs); e != nil {
		t.Fatal(e)
	}
	if e := s.Save(path); e != nil {
		t.Fatal(e)
	}
	m, e := Compile([]Rule{{Section: "block", Action: Block, Domains: []string{"a.test"}}})
	if e != nil {
		t.Fatal(e)
	}
	next := NewStore(f)
	if e = next.Restore(path, m, now); e != nil {
		t.Fatal(e)
	}
	if len(f.snapshot.Block4) != 1 || len(f.snapshot.Direct4) != 0 {
		t.Fatal("old Direct binding was not reclassified")
	}
}
