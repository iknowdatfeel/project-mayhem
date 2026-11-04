// DNS policy decisions are separate from forwarding and packet filtering.
package dnspolicy

import (
	"fmt"
	"net/netip"
	"regexp"
	"strings"
	"sync"
	"time"
)

type Action string

const (
	Block  Action = "block"
	Direct Action = "direct"
	Proxy  Action = "proxy"
)

type Rule struct {
	Section string   `json:"section"`
	Action  Action   `json:"action"`
	Domains []string `json:"domains"`
}

type pattern struct {
	section string
	action  Action
	text    string
	re      *regexp.Regexp
	order   int
}
type Decision struct {
	Action  Action
	Section string
	order   int
}

// Matcher is immutable after construction. Exact and suffix rules use maps;
// only keyword and regexp rules need a scan.
type Matcher struct {
	exact    map[string]Decision
	suffix   map[string]Decision
	keywords []pattern
	regexps  []pattern
}

func better(a, b Decision) Decision {
	priority := map[Action]int{Block: 3, Direct: 2, Proxy: 1}
	if priority[b.Action] > priority[a.Action] {
		return b
	}
	if priority[a.Action] > priority[b.Action] {
		return a
	}
	if a.Action == "" || b.order < a.order {
		return b
	}
	return a
}

func Compile(rules []Rule) (*Matcher, error) {
	m := &Matcher{exact: map[string]Decision{}, suffix: map[string]Decision{}}
	for order, r := range rules {
		if r.Action != Block && r.Action != Direct && r.Action != Proxy {
			return nil, fmt.Errorf("section %q: invalid DNS action %q", r.Section, r.Action)
		}
		for _, raw := range r.Domains {
			kind, value, found := strings.Cut(raw, ":")
			if !found {
				kind, value = "domain", raw
			}
			if value == "" {
				return nil, fmt.Errorf("section %q: empty %s rule", r.Section, kind)
			}
			d := Decision{r.Action, r.Section, order}
			switch kind {
			case "domain", "full":
				value = strings.TrimSuffix(strings.ToLower(value), ".")
				if !validName(value) {
					return nil, fmt.Errorf("section %q: invalid domain %q", r.Section, raw)
				}
				target := m.suffix
				if kind == "full" {
					target = m.exact
				}
				target[value] = better(target[value], d)
			case "keyword":
				m.keywords = append(m.keywords, pattern{r.Section, r.Action, strings.ToLower(value), nil, order})
			case "regexp":
				re, err := regexp.Compile(value)
				if err != nil {
					return nil, fmt.Errorf("section %q: regexp %q: %w", r.Section, value, err)
				}
				m.regexps = append(m.regexps, pattern{r.Section, r.Action, value, re, order})
			default:
				return nil, fmt.Errorf("section %q: unexpanded or unsupported DNS rule %q", r.Section, raw)
			}
		}
	}
	return m, nil
}

func validName(s string) bool {
	if s == "" || len(s) > 253 {
		return false
	}
	for _, label := range strings.Split(s, ".") {
		if len(label) == 0 || len(label) > 63 {
			return false
		}
		for _, c := range label {
			if !(c >= 'a' && c <= 'z' || c >= '0' && c <= '9' || c == '-' || c == '_') {
				return false
			}
		}
	}
	return true
}

func (m *Matcher) Match(name string) Decision {
	name = strings.TrimSuffix(strings.ToLower(name), ".")
	if !validName(name) {
		return Decision{}
	}
	d := m.exact[name]
	for suffix := name; suffix != ""; {
		d = better(d, m.suffix[suffix])
		_, next, ok := strings.Cut(suffix, ".")
		if !ok {
			break
		}
		suffix = next
	}
	for _, p := range m.keywords {
		if strings.Contains(name, p.text) {
			d = better(d, Decision{p.action, p.section, p.order})
		}
	}
	for _, p := range m.regexps {
		if p.re.MatchString(name) {
			d = better(d, Decision{p.action, p.section, p.order})
		}
	}
	return d
}

// Binding retains the queried name: expiration of one domain must not erase
// another live binding of the same address. Block wins on shared addresses.
type Binding struct {
	Name    string
	Address netip.Addr
	Action  Action
	Expires time.Time
}
type Snapshot struct{ Block4, Block6, Direct4, Direct6, Proxy4, Proxy6 []netip.Addr }
type Installer interface{ Replace(Snapshot) error }
type Store struct {
	mu        sync.Mutex
	bindings  map[string]Binding
	installer Installer
	statePath string
}

func NewStore(i Installer) *Store { return &Store{bindings: map[string]Binding{}, installer: i} }

// Commit must succeed before a DNS answer containing these addresses is sent.
// A failed kernel transaction leaves the previous policy intact.
func (s *Store) Commit(now time.Time, entries []Binding) error {
	s.mu.Lock()
	defer s.mu.Unlock()
	next := make(map[string]Binding, len(s.bindings)+len(entries))
	for k, b := range s.bindings {
		if b.Expires.After(now) {
			next[k] = b
		}
	}
	for _, b := range entries {
		if !b.Address.IsValid() || b.Address.Zone() != "" || (b.Action != Block && b.Action != Direct && b.Action != Proxy) {
			return fmt.Errorf("invalid DNS binding for %q", b.Name)
		}
		if !b.Expires.After(now) {
			continue
		}
		b.Address = b.Address.Unmap()
		key := strings.ToLower(b.Name) + "\x00" + b.Address.String() + "\x00" + string(b.Action)
		if old, ok := next[key]; ok && old.Expires.After(b.Expires) {
			b.Expires = old.Expires
		}
		next[key] = b
	}
	addresses := map[netip.Addr]Action{}
	priority := map[Action]int{Block: 3, Direct: 2, Proxy: 1}
	for _, b := range next {
		if priority[b.Action] > priority[addresses[b.Address]] {
			addresses[b.Address] = b.Action
		}
	}
	var snap Snapshot
	for addr, action := range addresses {
		switch action {
		case Block:
			if addr.Is4() {
				snap.Block4 = append(snap.Block4, addr)
			} else {
				snap.Block6 = append(snap.Block6, addr)
			}
		case Direct:
			if addr.Is4() {
				snap.Direct4 = append(snap.Direct4, addr)
			} else {
				snap.Direct6 = append(snap.Direct6, addr)
			}
		case Proxy:
			if addr.Is4() {
				snap.Proxy4 = append(snap.Proxy4, addr)
			} else {
				snap.Proxy6 = append(snap.Proxy6, addr)
			}
		}
	}

	if err := s.installer.Replace(snap); err != nil {
		return err
	}
	s.bindings = next
	if s.statePath != "" {
		return s.saveLocked(s.statePath)
	}
	return nil
}
