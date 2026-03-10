package abuse

import (
	"errors"
	"net"
	"strings"
	"sync"
	"time"

	"github.com/superdecrypt-dev/autoscript/opt/edge/go/internal/runtime"
)

var ErrRejected = errors.New("connection rejected by abuse guard")

type Guard struct {
	mu     sync.Mutex
	total  int
	active map[string]int
	recent map[string][]time.Time
}

func NewGuard() *Guard {
	return &Guard{
		active: make(map[string]int),
		recent: make(map[string][]time.Time),
	}
}

func (g *Guard) Acquire(cfg runtime.Config, remote net.Addr) (string, func(), error) {
	if g == nil {
		return "", func() {}, nil
	}
	now := time.Now()
	ip := remoteIP(remote)

	g.mu.Lock()
	defer g.mu.Unlock()

	if cfg.MaxConnections > 0 && g.total >= cfg.MaxConnections {
		return ip, nil, ErrRejected
	}
	if ip != "" {
		if cfg.AcceptRatePerIP > 0 {
			window := cfg.AcceptRateWindow
			cutoff := now.Add(-window)
			recent := g.recent[ip][:0]
			for _, ts := range g.recent[ip] {
				if ts.After(cutoff) {
					recent = append(recent, ts)
				}
			}
			g.recent[ip] = recent
			if len(recent) >= cfg.AcceptRatePerIP {
				return ip, nil, ErrRejected
			}
			g.recent[ip] = append(g.recent[ip], now)
		}
		if cfg.MaxConnectionsPerIP > 0 && g.active[ip] >= cfg.MaxConnectionsPerIP {
			return ip, nil, ErrRejected
		}
		g.active[ip]++
	}
	g.total++

	var once sync.Once
	release := func() {
		once.Do(func() {
			g.mu.Lock()
			defer g.mu.Unlock()
			if g.total > 0 {
				g.total--
			}
			if ip == "" {
				return
			}
			current := g.active[ip]
			switch {
			case current <= 1:
				delete(g.active, ip)
			default:
				g.active[ip] = current - 1
			}
		})
	}
	return ip, release, nil
}

func remoteIP(remote net.Addr) string {
	if remote == nil {
		return ""
	}
	text := strings.TrimSpace(remote.String())
	if text == "" {
		return ""
	}
	host, _, err := net.SplitHostPort(text)
	if err == nil {
		text = host
	}
	text = strings.Trim(text, "[]")
	if ip := net.ParseIP(text); ip != nil {
		return ip.String()
	}
	return ""
}
