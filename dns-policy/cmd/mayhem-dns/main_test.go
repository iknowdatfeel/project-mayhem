package main

import (
	"os"
	"path/filepath"
	"testing"
	"time"
)

// A new resolver must wait until the old resolver has drained its workers
// and deleted its table. Otherwise old cleanup can erase the new policy.
func TestResolverOwnershipSurvivesReplacement(t *testing.T) {
	path := filepath.Join(t.TempDir(), "policy.lock")
	old, err := acquirePolicyLock(path)
	if err != nil {
		t.Fatal(err)
	}
	defer old.Close()
	ready := make(chan *os.File, 1)
	failure := make(chan error, 1)
	go func() {
		next, err := acquirePolicyLock(path)
		if err != nil {
			failure <- err
			return
		}
		ready <- next
	}()
	select {
	case next := <-ready:
		next.Close()
		t.Fatal("replacement acquired policy before old cleanup finished")
	case err := <-failure:
		t.Fatal(err)
	case <-time.After(50 * time.Millisecond):
	}
	if err = old.Close(); err != nil {
		t.Fatal(err)
	}
	select {
	case next := <-ready:
		next.Close()
	case err := <-failure:
		t.Fatal(err)
	case <-time.After(time.Second):
		t.Fatal("replacement did not acquire released ownership")
	}
}
