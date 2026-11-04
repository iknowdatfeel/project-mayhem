package dnspolicy

import (
	"encoding/binary"
	"os"
	"path/filepath"
	"testing"
)

func pbBytes(field byte, b []byte) []byte {
	out := []byte{field<<3 | 2}
	out = binary.AppendUvarint(out, uint64(len(b)))
	return append(out, b...)
}
func TestGeoSiteAndAttributes(t *testing.T) {
	dir := t.TempDir()
	d1 := append([]byte{8, 2}, pbBytes(2, []byte("ads.test"))...)
	d1 = append(d1, pbBytes(3, pbBytes(1, []byte("selected")))...)
	d2 := append([]byte{8, 1}, pbBytes(2, []byte("^banner[0-9]+\\.test$"))...)
	entry := pbBytes(1, []byte("ADS"))
	entry = append(entry, pbBytes(2, d1)...)
	entry = append(entry, pbBytes(2, d2)...)
	if err := os.WriteFile(filepath.Join(dir, "s.dat"), pbBytes(1, entry), 0600); err != nil {
		t.Fatal(err)
	}
	for input, want := range map[string]int{"ext:s.dat:ads": 2, "ext:s.dat:ads@selected": 1} {
		rules, e := Expand([]Rule{{Section: "block", Action: Block, Domains: []string{input}}}, dir)
		if e != nil {
			t.Fatal(e)
		}
		if len(rules[0].Domains) != want {
			t.Fatalf("%s: %v", input, rules)
		}
		m, e := Compile(rules)
		if e != nil {
			t.Fatal(e)
		}
		if m.Match("x.ads.test").Action != Block {
			t.Fatal("GeoSite domain did not block subdomain")
		}
	}
	for _, input := range []string{"ext:../s.dat:ads", "ext:s.dat:missing"} {
		if _, e := Expand([]Rule{{Section: "block", Action: Block, Domains: []string{input}}}, dir); e == nil {
			t.Errorf("accepted %s", input)
		}
	}
}
