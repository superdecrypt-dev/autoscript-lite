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
	mu             sync.Mutex
	total          int
	active         map[string]int
	recent         map[string][]time.Time
	recentRejects  map[string][]time.Time
	blockedUntil   map[string]time.Time
	blockedReason  map[string]string
	blockedSurface map[string]string
	rejectReasons  map[string]uint64
	rejectSurfaces map[string]uint64
}

type Snapshot struct {
	ActiveIPs         int               `json:"active_ips"`
	ActiveConnections int               `json:"active_connections"`
	RateTrackedIPs    int               `json:"rate_tracked_ips"`
	RejectTrackedIPs  int               `json:"reject_tracked_ips"`
	CooldownBlockedIP int               `json:"cooldown_blocked_ips"`
	BlockedUntilUnix  map[string]int64  `json:"blocked_until_unix,omitempty"`
	BlockedReason     map[string]string `json:"blocked_reason,omitempty"`
	BlockedSurface    map[string]string `json:"blocked_surface,omitempty"`
	RejectReasons     map[string]uint64 `json:"reject_reasons,omitempty"`
	RejectSurfaces    map[string]uint64 `json:"reject_surfaces,omitempty"`
}

func NewGuard() *Guard {
	return &Guard{
		active:         make(map[string]int),
		recent:         make(map[string][]time.Time),
		recentRejects:  make(map[string][]time.Time),
		blockedUntil:   make(map[string]time.Time),
		blockedReason:  make(map[string]string),
		blockedSurface: make(map[string]string),
		rejectReasons:  make(map[string]uint64),
		rejectSurfaces: make(map[string]uint64),
	}
}

func (g *Guard) Acquire(cfg runtime.Config, remote net.Addr, surface string) (string, string, func(), error) {
	if g == nil {
		return "", "", func() {}, nil
	}
	now := time.Now()
	ip := remoteIP(remote)
	surface = strings.TrimSpace(surface)

	g.mu.Lock()
	defer g.mu.Unlock()

	g.pruneLocked(now, cfg)
	if ip != "" {
		if until, ok := g.blockedUntil[ip]; ok && until.After(now) {
			return ip, "cooldown", nil, ErrRejected
		}
	}

	if cfg.MaxConnections > 0 && g.total >= cfg.MaxConnections {
		g.recordRejectLocked(ip, now, cfg, "max_connections", surface)
		return ip, "max_connections", nil, ErrRejected
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
				g.recordRejectLocked(ip, now, cfg, "accept_rate", surface)
				return ip, "accept_rate", nil, ErrRejected
			}
			g.recent[ip] = append(g.recent[ip], now)
		}
		if cfg.MaxConnectionsPerIP > 0 && g.active[ip] >= cfg.MaxConnectionsPerIP {
			g.recordRejectLocked(ip, now, cfg, "max_connections_per_ip", surface)
			return ip, "max_connections_per_ip", nil, ErrRejected
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
	return ip, "", release, nil
}

func (g *Guard) ObserveFailure(cfg runtime.Config, remote net.Addr, surface, reason string) {
	if g == nil {
		return
	}
	ip := remoteIP(remote)
	if ip == "" {
		return
	}
	now := time.Now()
	g.mu.Lock()
	defer g.mu.Unlock()
	g.pruneLocked(now, cfg)
	g.recordRejectLocked(ip, now, cfg, strings.TrimSpace(reason), strings.TrimSpace(surface))
}

func (g *Guard) Snapshot() Snapshot {
	if g == nil {
		return Snapshot{}
	}
	now := time.Now()
	g.mu.Lock()
	defer g.mu.Unlock()
	g.pruneLocked(now, runtime.Config{
		AcceptRateWindow: defaultDuration(g.recentWindowGuess(), 10*time.Second),
		CooldownWindow:   defaultDuration(g.rejectWindowGuess(), 30*time.Second),
	})

	out := Snapshot{
		ActiveIPs:         len(g.active),
		ActiveConnections: g.total,
		RateTrackedIPs:    len(g.recent),
		RejectTrackedIPs:  len(g.recentRejects),
		CooldownBlockedIP: len(g.blockedUntil),
	}
	if len(g.blockedUntil) > 0 {
		out.BlockedUntilUnix = make(map[string]int64, len(g.blockedUntil))
		for ip, until := range g.blockedUntil {
			out.BlockedUntilUnix[ip] = until.Unix()
		}
	}
	if len(g.blockedReason) > 0 {
		out.BlockedReason = make(map[string]string, len(g.blockedReason))
		for ip, reason := range g.blockedReason {
			out.BlockedReason[ip] = reason
		}
	}
	if len(g.blockedSurface) > 0 {
		out.BlockedSurface = make(map[string]string, len(g.blockedSurface))
		for ip, surface := range g.blockedSurface {
			out.BlockedSurface[ip] = surface
		}
	}
	if len(g.rejectReasons) > 0 {
		out.RejectReasons = make(map[string]uint64, len(g.rejectReasons))
		for reason, total := range g.rejectReasons {
			out.RejectReasons[reason] = total
		}
	}
	if len(g.rejectSurfaces) > 0 {
		out.RejectSurfaces = make(map[string]uint64, len(g.rejectSurfaces))
		for surface, total := range g.rejectSurfaces {
			out.RejectSurfaces[surface] = total
		}
	}
	return out
}

func (g *Guard) pruneLocked(now time.Time, cfg runtime.Config) {
	cutoffRate := now.Add(-defaultDuration(cfg.AcceptRateWindow, 10*time.Second))
	for ip, recent := range g.recent {
		kept := recent[:0]
		for _, ts := range recent {
			if ts.After(cutoffRate) {
				kept = append(kept, ts)
			}
		}
		if len(kept) == 0 {
			delete(g.recent, ip)
			continue
		}
		g.recent[ip] = kept
	}

	cutoffReject := now.Add(-defaultDuration(cfg.CooldownWindow, 30*time.Second))
	for ip, recent := range g.recentRejects {
		kept := recent[:0]
		for _, ts := range recent {
			if ts.After(cutoffReject) {
				kept = append(kept, ts)
			}
		}
		if len(kept) == 0 {
			delete(g.recentRejects, ip)
			continue
		}
		g.recentRejects[ip] = kept
	}

	for ip, until := range g.blockedUntil {
		if !until.After(now) {
			delete(g.blockedUntil, ip)
			delete(g.blockedReason, ip)
			delete(g.blockedSurface, ip)
		}
	}
}

func (g *Guard) recordRejectLocked(ip string, now time.Time, cfg runtime.Config, reason, surface string) {
	reason = strings.TrimSpace(reason)
	if reason == "" {
		reason = "abuse"
	}
	surface = strings.TrimSpace(surface)
	if surface == "" {
		surface = "unknown"
	}
	g.rejectReasons[reason]++
	g.rejectSurfaces[surface]++
	if ip == "" || cfg.CooldownRejects <= 0 || cfg.CooldownDuration <= 0 {
		return
	}
	cutoff := now.Add(-defaultDuration(cfg.CooldownWindow, 30*time.Second))
	recent := g.recentRejects[ip][:0]
	for _, ts := range g.recentRejects[ip] {
		if ts.After(cutoff) {
			recent = append(recent, ts)
		}
	}
	recent = append(recent, now)
	g.recentRejects[ip] = recent
	if len(recent) >= cfg.CooldownRejects {
		g.blockedUntil[ip] = now.Add(cfg.CooldownDuration)
		g.blockedReason[ip] = reason
		g.blockedSurface[ip] = surface
		delete(g.recentRejects, ip)
	}
}

func defaultDuration(value, fallback time.Duration) time.Duration {
	if value > 0 {
		return value
	}
	return fallback
}

func (g *Guard) recentWindowGuess() time.Duration {
	for _, recent := range g.recent {
		if len(recent) >= 2 {
			return recent[len(recent)-1].Sub(recent[0])
		}
	}
	return 0
}

func (g *Guard) rejectWindowGuess() time.Duration {
	for _, recent := range g.recentRejects {
		if len(recent) >= 2 {
			return recent[len(recent)-1].Sub(recent[0])
		}
	}
	return 0
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
