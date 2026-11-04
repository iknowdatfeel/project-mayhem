package dnspolicy

import (
	"encoding/binary"
	"fmt"
	"net/netip"
	"strings"
	"time"
)

type Question struct {
	Name        string
	Type, Class uint16
}

func dnsName(msg []byte, start int) (string, int, error) {
	p, end, size := start, -1, 0
	labels := []string{}
	seen := map[int]bool{}
	for steps := 0; steps < 128; steps++ {
		if p < 0 || p >= len(msg) || seen[p] {
			return "", 0, fmt.Errorf("invalid DNS name pointer")
		}
		seen[p] = true
		n := int(msg[p])
		p++
		if n == 0 {
			if end < 0 {
				end = p
			}
			return strings.ToLower(strings.Join(labels, ".")), end, nil
		}
		if n&0xc0 == 0xc0 {
			if p >= len(msg) {
				return "", 0, fmt.Errorf("truncated DNS pointer")
			}
			if end < 0 {
				end = p + 1
			}
			p = (n&0x3f)<<8 | int(msg[p])
			continue
		}
		if n&0xc0 != 0 || p+n > len(msg) {
			return "", 0, fmt.Errorf("invalid DNS label")
		}
		size += n + 1
		if size > 254 {
			return "", 0, fmt.Errorf("DNS name too long")
		}
		label := string(msg[p : p+n])
		// Names containing literal dots or control bytes must not be treated
		// as printable policy names with a different label structure.
		for _, c := range []byte(label) {
			if c <= 32 || c >= 127 || c == '.' {
				return "", 0, fmt.Errorf("unsupported DNS label encoding")
			}
		}
		labels = append(labels, label)
		p += n
	}
	return "", 0, fmt.Errorf("too many DNS name indirections")
}

func ParseQuestion(msg []byte) (Question, error) {
	if len(msg) < 12 || binary.BigEndian.Uint16(msg[4:6]) != 1 {
		return Question{}, fmt.Errorf("DNS packet must have one question")
	}
	name, end, err := dnsName(msg, 12)
	if err != nil {
		return Question{}, err
	}
	if end+4 > len(msg) {
		return Question{}, fmt.Errorf("truncated DNS question")
	}
	return Question{name, binary.BigEndian.Uint16(msg[end : end+2]), binary.BigEndian.Uint16(msg[end+2 : end+4])}, nil
}

// AnswerBindings validates the response before trusting its address records.
// Only addresses attached to the question's CNAME chain are included; unrelated
// answer records cannot inject an arbitrary address into a policy set.
func AnswerBindings(query, answer []byte, action Action, now time.Time) ([]Binding, error) {
	q, err := ParseQuestion(query)
	if err != nil {
		return nil, err
	}
	a, err := ParseQuestion(answer)
	if err != nil {
		return nil, err
	}
	if q != a || len(answer) < 12 || answer[0] != query[0] || answer[1] != query[1] || answer[2]&0x80 == 0 || answer[2]&0x78 != query[2]&0x78 {
		return nil, fmt.Errorf("DNS response does not match query")
	}
	// Truncated/error responses are not evidence of a complete address set.
	if answer[2]&2 != 0 || answer[3]&15 != 0 || q.Class != 1 {
		return nil, nil
	}
	_, p, _ := dnsName(answer, 12)
	p += 4
	type rr struct {
		owner, alias string
		addr         netip.Addr
		ttl          uint32
	}
	records := []rr{}
	for n := int(binary.BigEndian.Uint16(answer[6:8])); n > 0; n-- {
		owner, end, err := dnsName(answer, p)
		if err != nil {
			return nil, err
		}
		p = end
		if p+10 > len(answer) {
			return nil, fmt.Errorf("truncated DNS answer")
		}
		typ, class := binary.BigEndian.Uint16(answer[p:p+2]), binary.BigEndian.Uint16(answer[p+2:p+4])
		ttl := binary.BigEndian.Uint32(answer[p+4 : p+8])
		size := int(binary.BigEndian.Uint16(answer[p+8 : p+10]))
		p += 10
		if p+size > len(answer) {
			return nil, fmt.Errorf("truncated DNS record")
		}
		if class == 1 {
			r := rr{owner: owner, ttl: ttl}
			switch {
			case typ == 5:
				alias, end, err := dnsName(answer, p)
				if err != nil || end != p+size {
					return nil, fmt.Errorf("invalid DNS CNAME")
				}
				r.alias = alias
			case typ == 1 && size == 4:
				r.addr = netip.AddrFrom4([4]byte(answer[p : p+4]))
			case typ == 28 && size == 16:
				r.addr = netip.AddrFrom16([16]byte(answer[p : p+16]))
			}
			records = append(records, r)
		}
		p += size
	}
	name, ttl := q.Name, uint32(0xffffffff)
	seen := map[string]bool{}
	for steps := 0; steps <= len(records); steps++ {
		if seen[name] {
			return nil, fmt.Errorf("DNS CNAME loop")
		}
		seen[name] = true
		alias := ""
		for _, r := range records {
			if r.owner == name && r.alias != "" {
				if alias != "" && alias != r.alias {
					return nil, fmt.Errorf("conflicting DNS CNAME records")
				}
				alias = r.alias
				if r.ttl < ttl {
					ttl = r.ttl
				}
			}
		}
		if alias != "" {
			name = alias
			continue
		}
		var out []Binding
		for _, r := range records {
			if r.owner != name || !r.addr.IsValid() {
				continue
			}
			lifetime := r.ttl
			if ttl < lifetime {
				lifetime = ttl
			}
			// A zero-TTL answer still authorizes the current connection. Keep
			// a short admission window; the DNS reply itself retains TTL zero.
			if lifetime == 0 {
				lifetime = 5
			}
			out = append(out, Binding{q.Name, r.addr, action, now.Add(time.Duration(lifetime) * time.Second)})
		}
		return out, nil
	}
	return nil, fmt.Errorf("DNS CNAME chain too long")
}
