package main

import (
	"context"
	"encoding/json"
	"flag"
	"fmt"
	policy "github.com/iknowdatfeel/project-mayhem/dns-policy"
	"log"
	"os"
	"os/exec"
	"os/signal"
	"path/filepath"
	"syscall"
	"time"
)

func main() {
	config := flag.String("config", "/var/run/mayhem/dns-policy.json", "generated policy configuration")
	geo := flag.String("geo", "/etc/mayhem/geo", "trimmed GeoSite directory")
	check := flag.Bool("check", false, "validate configuration without opening sockets or changing nftables")
	emit := flag.Bool("emit", false, "write the validated configuration with expanded GeoSite rules")
	version := flag.Bool("version", false, "print version")
	flag.Parse()
	if *version {
		fmt.Println("mayhem-dns 1")
		return
	}
	raw, err := os.ReadFile(*config)
	if err != nil {
		log.Fatal(err)
	}
	var cfg policy.Config
	if err = json.Unmarshal(raw, &cfg); err != nil {
		log.Fatal(err)
	}
	cfg.Rules, err = policy.Expand(cfg.Rules, *geo)
	if err != nil {
		log.Fatal(err)
	}
	matcher, err := policy.Compile(cfg.Rules)
	if err != nil {
		log.Fatal(err)
	}
	nft := &policy.NFTInstaller{Config: cfg}
	if _, err = nft.Script(policy.Snapshot{}); err != nil {
		log.Fatal(err)
	}
	if *check {
		if *emit {
			if err := json.NewEncoder(os.Stdout).Encode(cfg); err != nil {
				log.Fatal(err)
			}
		}
		return
	}
	// Hold ownership through listener shutdown, worker draining and table
	// cleanup. A replacement process must not install its table earlier.
	lock, err := acquirePolicyLock(filepath.Join(filepath.Dir(*config), "dns-policy.lock"))
	if err != nil {
		log.Fatal(err)
	}
	defer lock.Close()
	store := policy.NewStore(nft)
	state := filepath.Join(filepath.Dir(*config), "dns-policy.bindings.json")
	if err = store.Restore(state, matcher, time.Now()); err != nil {
		log.Fatal(err)
	}
	store.PersistBeforeReply(state)
	ctx, cancel := signal.NotifyContext(context.Background(), syscall.SIGTERM, syscall.SIGINT)
	defer cancel()
	status := filepath.Join(filepath.Dir(*config), "dns-policy.error")
	gcDone := make(chan struct{})
	go func() {
		defer close(gcDone)
		ticker := time.NewTicker(time.Second)
		defer ticker.Stop()
		for {
			select {
			case <-ctx.Done():
				if e := store.Save(state); e != nil {
					log.Printf("save DNS policy: %v", e)
				}
				return
			case now := <-ticker.C:
				if e := store.Save(state); e != nil {
					log.Printf("save DNS policy: %v", e)
				}
				if e := store.Commit(now, nil); e != nil {
					log.Printf("expire DNS policy: %v", e)
					os.WriteFile(status, []byte(e.Error()), 0600)
				}
			}
		}
	}()
	server := policy.Server{SectionDNS: cfg.SectionDNS, Matcher: matcher, Store: store, Domestic: cfg.Domestic, UpstreamsFile: cfg.UpstreamsFile, ISPFile: cfg.ISPFile}
	if err = server.Serve(ctx, cfg.Listen); err != nil {
		os.WriteFile(status, []byte(err.Error()), 0600)
		log.Fatal(err)
	}
	<-gcDone
	cleanup, stop := context.WithTimeout(context.Background(), 2*time.Second)
	defer stop()
	_ = exec.CommandContext(cleanup, "nft", "delete", "table", "inet", "mayhem_policy").Run()

}

func acquirePolicyLock(path string) (*os.File, error) {
	f, err := os.OpenFile(path, os.O_CREATE|os.O_RDWR, 0600)
	if err != nil {
		return nil, err
	}
	if err = syscall.Flock(int(f.Fd()), syscall.LOCK_EX); err != nil {
		f.Close()
		return nil, err
	}
	return f, nil
}
