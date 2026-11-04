package dnspolicy

import (
	"encoding/binary"
	"testing"
	"time"
)

func nameWire(s string) []byte {
	out := []byte{}
	start := 0
	for i := 0; i <= len(s); i++ {
		if i == len(s) || s[i] == '.' {
			out = append(out, byte(i-start))
			out = append(out, s[start:i]...)
			start = i + 1
		}
	}
	return append(out, 0)
}
func queryWire(name string) []byte {
	q := make([]byte, 12)
	q[0] = 12
	q[1] = 34
	q[2] = 1
	q[5] = 1
	q = append(q, nameWire(name)...)
	return append(q, 0, 1, 0, 1)
}
func rrWire(owner []byte, typ uint16, ttl uint32, data []byte) []byte {
	b := append([]byte(nil), owner...)
	h := make([]byte, 10)
	binary.BigEndian.PutUint16(h, typ)
	binary.BigEndian.PutUint16(h[2:], 1)
	binary.BigEndian.PutUint32(h[4:], ttl)
	binary.BigEndian.PutUint16(h[8:], uint16(len(data)))
	b = append(b, h...)
	return append(b, data...)
}
func TestCNAMEBindings(t *testing.T) {
	q := queryWire("download.windowsupdate.com")
	a := append([]byte(nil), q...)
	a[2] = 0x81
	a[3] = 0x80
	a[7] = 3
	a = append(a, rrWire([]byte{0xc0, 12}, 5, 10, nameWire("cdn.test"))...)
	a = append(a, rrWire(nameWire("cdn.test"), 1, 60, []byte{203, 0, 113, 10})...)
	a = append(a, rrWire(nameWire("unrelated.test"), 1, 60, []byte{203, 0, 113, 11})...)
	now := time.Unix(1000, 0)
	bs, err := AnswerBindings(q, a, Block, now)
	if err != nil {
		t.Fatal(err)
	}
	if len(bs) != 1 || bs[0].Address.String() != "203.0.113.10" || !bs[0].Expires.Equal(now.Add(10*time.Second)) {
		t.Fatalf("wrong CNAME bindings: %+v", bs)
	}
	a[0]++
	if _, err = AnswerBindings(q, a, Block, now); err == nil {
		t.Fatal("accepted unrelated transaction")
	}
}
func TestMalformedDNS(t *testing.T) {
	for _, packet := range [][]byte{{}, {0, 0}, append(make([]byte, 12), 0xc0, 12)} {
		if _, err := ParseQuestion(packet); err == nil {
			t.Fatal("accepted malformed DNS packet")
		}
	}
	q := queryWire("a.test")
	a := append([]byte(nil), q...)
	a[2] = 0x81
	a[7] = 1
	a = append(a, rrWire([]byte{0xc0, 12}, 1, 10, []byte{1, 2, 3, 4})...)
	for n := len(q); n < len(a); n++ {
		if _, err := AnswerBindings(q, a[:n], Block, time.Now()); err == nil {
			t.Fatalf("accepted truncated answer at %d", n)
		}
	}
}
func FuzzDNSPacket(f *testing.F) {
	f.Add(queryWire("download.windowsupdate.com"))
	f.Add([]byte{0xc0, 0})
	f.Fuzz(func(t *testing.T, b []byte) {
		ParseQuestion(b)
		AnswerBindings(queryWire("a.test"), b, Block, time.Now())
	})
}
