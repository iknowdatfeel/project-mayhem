package dnspolicy

import (
	"context"
	"crypto/rand"
	"encoding/binary"
	"fmt"
	"io"
	"log"
	"net"
	"os"
	"strconv"
	"strings"
	"sync"
	"time"
)

type Server struct {
	SectionDNS    map[string][]string
	Matcher       *Matcher
	Store         *Store
	Domestic      []string
	UpstreamsFile string
	ISPFile       string
	MaxConcurrent int
}

func serverLines(path, name string) []string {
	b, err := os.ReadFile(path)
	if err != nil {
		return nil
	}
	best := -1
	var out []string
	for _, line := range strings.Split(string(b), "\n") {
		if !strings.HasPrefix(line, "server=") {
			continue
		}
		v := strings.TrimPrefix(line, "server=")
		score := 0
		if strings.HasPrefix(v, "/") {
			fields := strings.Split(v, "/")
			if len(fields) < 3 {
				continue
			}
			v = fields[len(fields)-1]
			score = -1
			for _, domain := range fields[1 : len(fields)-1] {
				domain = strings.TrimPrefix(domain, ".")
				if domain != "" && (name == domain || strings.HasSuffix(name, "."+domain)) && len(domain) > score {
					score = len(domain)
				}
			}
			if score < 0 {
				continue
			}
		}
		host, port := v, "53"
		if i := strings.LastIndex(v, "#"); i >= 0 {
			host, port = v[:i], v[i+1:]
		}
		if net.ParseIP(host) == nil {
			continue
		}
		if n, e := strconv.Atoi(port); e != nil || n < 1 || n > 65535 {
			continue
		}
		if score > best {
			best = score
			out = nil
		}
		if score == best {
			out = append(out, net.JoinHostPort(host, port))
		}
	}
	return out
}

func exchange(query []byte, upstream string, tcp bool) ([]byte, error) {
	network := "udp"
	if tcp {
		network = "tcp"
	}
	dialer := upstreamDialer()
	dialer.Timeout = 2 * time.Second
	c, err := dialer.Dial(network, upstream)
	if err != nil {
		return nil, err
	}
	defer c.Close()
	if err = c.SetDeadline(time.Now().Add(3 * time.Second)); err != nil {
		return nil, err
	}
	q := append([]byte(nil), query...)
	if len(q) < 12 {
		return nil, fmt.Errorf("short DNS query")
	}
	if _, err = rand.Read(q[:2]); err != nil {
		return nil, err
	}
	if tcp {
		frame := make([]byte, len(q)+2)
		binary.BigEndian.PutUint16(frame, uint16(len(q)))
		copy(frame[2:], q)
		if _, err = io.Copy(c, strings.NewReader(string(frame))); err != nil {
			return nil, err
		}
		var n [2]byte
		if _, err = io.ReadFull(c, n[:]); err != nil {
			return nil, err
		}
		answer := make([]byte, int(binary.BigEndian.Uint16(n[:])))
		if _, err = io.ReadFull(c, answer); err != nil {
			return nil, err
		}
		if err = validateResponse(q, answer); err != nil {
			return nil, err
		}
		copy(answer[:2], query[:2])
		return answer, nil
	}
	if _, err = c.Write(q); err != nil {
		return nil, err
	}
	answer := make([]byte, 65535)
	n, err := c.Read(answer)
	if err != nil {
		return nil, err
	}
	answer = answer[:n]
	if err = validateResponse(q, answer); err != nil {
		return nil, err
	}
	if answer[2]&2 != 0 {
		return exchange(query, upstream, true)
	}
	copy(answer[:2], query[:2])
	return answer, nil
}
func validateResponse(q, a []byte) error {
	qq, e := ParseQuestion(q)
	if e != nil {
		return e
	}
	aq, e := ParseQuestion(a)
	if e != nil {
		return e
	}
	if qq != aq || len(a) < 12 || a[0] != q[0] || a[1] != q[1] || a[2]&0x80 == 0 || a[2]&0x78 != q[2]&0x78 {
		return fmt.Errorf("DNS response does not match query")
	}
	return nil
}
func failure(query []byte) []byte {
	if len(query) < 12 {
		return nil
	}
	q := append([]byte(nil), query...)
	q[2] = (q[2] & 1) | 0x80
	q[3] = 0x82
	for i := 6; i < 12; i++ {
		q[i] = 0
	}
	_, p, err := dnsName(q, 12)
	if err != nil || p+4 > len(q) {
		return nil
	}
	return q[:p+4]
}
func (s *Server) Handle(query []byte) ([]byte, error) {
	q, err := ParseQuestion(query)
	if err != nil {
		return nil, err
	}
	if query[2]&0xf8 != 0 {
		return nil, fmt.Errorf("only standard DNS queries are supported")
	}
	d := s.Matcher.Match(q.Name)
	upstreams := serverLines(s.UpstreamsFile, q.Name)
	if d.Action == Block || d.Action == Direct {
		upstreams = s.Domestic
		if custom := s.SectionDNS[d.Section]; len(custom) > 0 {
			upstreams = custom
		}
		if len(upstreams) == 0 {
			upstreams = serverLines(s.ISPFile, q.Name)
		}
	}
	if len(upstreams) == 0 {
		return nil, fmt.Errorf("no DNS upstream for %s", q.Name)
	}
	var last error
	for _, u := range upstreams {
		answer, e := exchange(query, u, false)
		if e != nil {
			last = e
			continue
		}
		action := d.Action

		if action != "" {
			bindings, e := AnswerBindings(query, answer, action, time.Now())
			if e != nil {
				return nil, e
			}
			if e = s.Store.Commit(time.Now(), bindings); e != nil {
				return nil, fmt.Errorf("DNS policy %s: %w", d.Section, e)
			}
		}
		return answer, nil
	}
	return nil, last
}

// Listeners bind to loopback only. Bounded workers prevent an upstream outage
// from creating an unlimited number of sockets and goroutines.
func (s *Server) Serve(ctx context.Context, address string) error {
	host, _, err := net.SplitHostPort(address)
	if err != nil || net.ParseIP(host) == nil || !net.ParseIP(host).IsLoopback() {
		return fmt.Errorf("DNS policy listener must be loopback")
	}
	udp, err := net.ListenPacket("udp", address)
	if err != nil {
		return err
	}
	defer udp.Close()
	tcp, err := net.Listen("tcp", address)
	if err != nil {
		return err
	}
	defer tcp.Close()
	limit := s.MaxConcurrent
	if limit < 1 {
		limit = 64
	}
	sem := make(chan struct{}, limit)
	var wg sync.WaitGroup
	go func() { <-ctx.Done(); udp.Close(); tcp.Close() }()
	acceptDone := make(chan struct{})
	go func() {
		defer close(acceptDone)
		for {
			c, e := tcp.Accept()
			if e != nil {
				return
			}
			select {
			case sem <- struct{}{}:
			default:
				c.Close()
				continue
			}
			wg.Add(1)
			go func() {
				defer wg.Done()
				defer func() { <-sem }()
				defer c.Close()
				for {
					c.SetDeadline(time.Now().Add(10 * time.Second))
					var frame [2]byte
					if _, e := io.ReadFull(c, frame[:]); e != nil {
						return
					}
					n := int(binary.BigEndian.Uint16(frame[:]))
					if n < 12 {
						return
					}
					q := make([]byte, n)
					if _, e := io.ReadFull(c, q); e != nil {
						return
					}
					a, e := s.Handle(q)
					if e != nil {
						log.Printf("DNS policy: %v", e)
						a = failure(q)
					}
					if len(a) == 0 {
						return
					}
					binary.BigEndian.PutUint16(frame[:], uint16(len(a)))
					out := append(frame[:], a...)
					if _, e := io.Copy(c, strings.NewReader(string(out))); e != nil {
						return
					}
				}
			}()
		}
	}()
	for {
		buf := make([]byte, 65535)
		n, peer, e := udp.ReadFrom(buf)
		if e != nil {
			if ctx.Err() != nil {
				<-acceptDone
				wg.Wait()
				return nil
			}
			return e
		}
		q := buf[:n]
		select {
		case sem <- struct{}{}:
		default:
			continue
		}
		wg.Add(1)
		go func() {
			defer wg.Done()
			defer func() { <-sem }()
			a, e := s.Handle(q)
			if e != nil {
				log.Printf("DNS policy: %v", e)
				a = failure(q)
			}
			if len(a) > 512 {
				_, end, parseErr := dnsName(a, 12)
				if parseErr != nil || end+4 > len(a) {
					return
				}
				a = append([]byte(nil), a[:end+4]...)
				a[2] |= 2
				for i := 6; i < 12; i++ {
					a[i] = 0
				}
			}
			if len(a) > 0 {
				udp.WriteTo(a, peer)
			}
		}()
	}
}
