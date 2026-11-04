package dnspolicy

import (
	"encoding/json"
	"fmt"
	"os"
	"time"
)

// Restore re-evaluates names under the new policy. A removed rule must not
// leave a formerly blocked address behind until its old DNS TTL expires.
func (s *Store) Restore(path string, m *Matcher, now time.Time) error {
	b, err := os.ReadFile(path)
	if os.IsNotExist(err) {
		return s.Commit(now, nil)
	}
	if err != nil {
		return err
	}
	var entries []Binding
	if err = json.Unmarshal(b, &entries); err != nil {
		return fmt.Errorf("read DNS policy state: %w", err)
	}
	next := []Binding{}
	for _, b := range entries {
		d := m.Match(b.Name)
		if d.Action == "" && b.Action == Proxy {
			d.Action = Proxy
		}
		if d.Action != "" && b.Expires.After(now) {
			b.Action = d.Action
			next = append(next, b)
		}
	}
	return s.Commit(now, next)
}
func (s *Store) Save(path string) error {
	s.mu.Lock()
	defer s.mu.Unlock()
	return s.saveLocked(path)
}
func (s *Store) saveLocked(path string) error {
	entries := make([]Binding, 0, len(s.bindings))
	for _, b := range s.bindings {
		entries = append(entries, b)
	}
	data, err := json.Marshal(entries)
	if err != nil {
		return err
	}
	tmp := path + ".new"
	if err = os.WriteFile(tmp, data, 0600); err != nil {
		return err
	}
	return os.Rename(tmp, path)
}

// PersistBeforeReply enables durable-in-RAM state updates during Commit.
func (s *Store) PersistBeforeReply(path string) { s.mu.Lock(); defer s.mu.Unlock(); s.statePath = path }
