package dnspolicy

import (
	"encoding/binary"
	"fmt"
	"os"
	"path/filepath"
	"strings"
)

type field struct {
	number, value, wire uint64
	data                []byte
}

func fields(data []byte) ([]field, error) {
	out := []field{}
	for len(data) > 0 {
		tag, n := binary.Uvarint(data)
		if n <= 0 || tag>>3 == 0 {
			return nil, fmt.Errorf("invalid geosite field")
		}
		data = data[n:]
		f := field{number: tag >> 3, wire: tag & 7}
		switch f.wire {
		case 0:
			v, n := binary.Uvarint(data)
			if n <= 0 {
				return nil, fmt.Errorf("invalid geosite integer")
			}
			f.value = v
			data = data[n:]
		case 2:
			v, n := binary.Uvarint(data)
			if n <= 0 || v > uint64(len(data)-n) {
				return nil, fmt.Errorf("invalid geosite length")
			}
			f.data = data[n : n+int(v)]
			data = data[n+int(v):]
		case 1:
			if len(data) < 8 {
				return nil, fmt.Errorf("short geosite field")
			}
			data = data[8:]
		case 5:
			if len(data) < 4 {
				return nil, fmt.Errorf("short geosite field")
			}
			data = data[4:]
		default:
			return nil, fmt.Errorf("unsupported geosite wire type %d", f.wire)
		}
		out = append(out, f)
	}
	return out, nil
}
func category(data []byte, code, attribute string) ([]string, bool, error) {
	fs, err := fields(data)
	if err != nil {
		return nil, false, err
	}
	name := ""
	for _, f := range fs {
		if f.number == 1 && f.wire == 2 {
			name = string(f.data)
		}
	}
	if !strings.EqualFold(name, code) {
		return nil, false, nil
	}
	out := []string{}
	for _, f := range fs {
		if f.number != 2 || f.wire != 2 {
			continue
		}
		ds, err := fields(f.data)
		if err != nil {
			return nil, false, err
		}
		typ := uint64(0)
		value := ""
		attrs := map[string]bool{}
		for _, d := range ds {
			switch {
			case d.number == 1 && d.wire == 0:
				typ = d.value
			case d.number == 2 && d.wire == 2:
				value = string(d.data)
			case d.number == 3 && d.wire == 2:
				as, err := fields(d.data)
				if err != nil {
					return nil, false, err
				}
				for _, a := range as {
					if a.number == 1 && a.wire == 2 {
						attrs[string(a.data)] = true
					}
				}
			}
		}
		if attribute != "" && !attrs[attribute] {
			continue
		}
		kinds := []string{"keyword:", "regexp:", "domain:", "full:"}
		if typ > 3 {
			return nil, false, fmt.Errorf("unknown geosite domain type %d", typ)
		}
		out = append(out, kinds[typ]+value)
	}
	return out, true, nil
}

// Expand resolves references in the trimmed geo files maintained by Mayhem.
func Expand(rules []Rule, geoDir string) ([]Rule, error) {
	files := map[string][]byte{}
	cache := map[string][]string{}
	out := []Rule{}
	for _, r := range rules {
		next := Rule{Section: r.Section, Action: r.Action}
		for _, d := range r.Domains {
			if !strings.HasPrefix(d, "ext:") {
				next.Domains = append(next.Domains, d)
				continue
			}
			parts := strings.SplitN(strings.TrimPrefix(d, "ext:"), ":", 2)
			if len(parts) != 2 || filepath.Base(parts[0]) != parts[0] || parts[0] == "." || parts[0] == ".." {
				return nil, fmt.Errorf("section %q: invalid geo reference %q", r.Section, d)
			}
			values, ok := cache[d]
			if !ok {
				code, attr, _ := strings.Cut(parts[1], "@")
				if code == "" || strings.Contains(attr, "@") {
					return nil, fmt.Errorf("invalid geosite category %q", parts[1])
				}
				data, ok := files[parts[0]]
				if !ok {
					var err error
					data, err = os.ReadFile(filepath.Join(geoDir, parts[0]))
					if err != nil {
						return nil, err
					}
					files[parts[0]] = data
				}
				fs, err := fields(data)
				if err != nil {
					return nil, err
				}
				found := false
				for _, f := range fs {
					if f.number == 1 && f.wire == 2 {
						v, yes, err := category(f.data, code, attr)
						if err != nil {
							return nil, err
						}
						if yes {
							values = append(values, v...)
							found = true
						}
					}
				}
				if !found {
					return nil, fmt.Errorf("section %q: missing geosite category %q", r.Section, d)
				}
				cache[d] = values
			}
			next.Domains = append(next.Domains, values...)
		}
		out = append(out, next)
	}
	return out, nil
}
