package accounting

import (
	"crypto/rand"
	"encoding/hex"
	"fmt"
	"log"
	"net"
	"os"
	"path/filepath"
	"strings"
	"sync"
	"time"
)

const (
	startupResolveInterval = 250 * time.Millisecond
	startupResolveWindow   = 10 * time.Second
)

type UsernameResolver func() string

type XrayRuntimeSessionTracker struct {
	logger     *log.Logger
	cfg        XrayQuotaConfig
	localPort  int
	clientIP   string
	transport  string
	backend    string
	resolver   UsernameResolver
	heartbeat  time.Duration
	sessionID  string
	createdAt  int64
	done       chan struct{}
	onceStart  sync.Once
	onceStop   sync.Once
	activeFile string
}

func NewXrayRuntimeSessionTracker(logger *log.Logger, cfg XrayQuotaConfig, localPort int, clientIP, transport string, resolver UsernameResolver) *XrayRuntimeSessionTracker {
	if cfg.SessionRoot == "" || cfg.SessionHeartbeat <= 0 {
		return nil
	}
	return &XrayRuntimeSessionTracker{
		logger:    logger,
		cfg:       cfg,
		localPort: localPort,
		clientIP:  normalizeSessionIP(clientIP),
		transport: strings.TrimSpace(transport),
		backend:   "xray",
		resolver:  resolver,
		heartbeat: cfg.SessionHeartbeat,
		sessionID: fmt.Sprintf("edge-%d-%d-%s", os.Getpid(), localPort, randomHex(4)),
		createdAt: time.Now().Unix(),
		done:      make(chan struct{}),
	}
}

func (t *XrayRuntimeSessionTracker) Start() {
	if t == nil {
		return
	}
	t.onceStart.Do(func() {
		go t.run()
	})
}

func (t *XrayRuntimeSessionTracker) Stop() {
	if t == nil {
		return
	}
	t.onceStop.Do(func() {
		close(t.done)
		if t.activeFile != "" {
			_ = os.Remove(t.activeFile)
		}
	})
}

func (t *XrayRuntimeSessionTracker) run() {
	started := time.Now()

	for {
		resolved := t.update()
		wait := t.heartbeat
		if !resolved && time.Since(started) < startupResolveWindow {
			wait = startupResolveInterval
		}
		select {
		case <-t.done:
			return
		case <-time.After(wait):
		}
	}
}

func (t *XrayRuntimeSessionTracker) update() bool {
	username := t.resolveUsername()
	if err := os.MkdirAll(t.cfg.SessionRoot, 0o750); err != nil {
		if t.logger != nil {
			t.logger.Printf("edge-mux session mkdir failed root=%s: %v", t.cfg.SessionRoot, err)
		}
		return username != ""
	}
	target := filepath.Join(t.cfg.SessionRoot, t.sessionID+".json")
	payload := map[string]any{
		"username":   username,
		"client_ip":  t.clientIP,
		"transport":  t.transport,
		"backend":    t.backend,
		"local_port": t.localPort,
		"proxy_pid":  os.Getpid(),
		"created_at": t.createdAt,
		"updated_at": time.Now().Unix(),
		"source":     "edge-mux",
	}
	if err := writeJSONAtomic(target, payload); err != nil {
		if t.logger != nil {
			t.logger.Printf("edge-mux session write failed file=%s: %v", target, err)
		}
		return username != ""
	}
	if err := os.Chmod(target, 0o600); err != nil && t.logger != nil {
		t.logger.Printf("edge-mux session chmod failed file=%s: %v", target, err)
	}
	if t.activeFile == "" {
		t.activeFile = target
	}
	return username != ""
}

func (t *XrayRuntimeSessionTracker) resolveUsername() string {
	if t == nil {
		return ""
	}
	if t.resolver != nil {
		if user := normalizeUser(t.resolver()); user != "" {
			return user
		}
	}
	return ""
}

func normalizeSessionIP(raw string) string {
	text := strings.TrimSpace(raw)
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

func randomHex(n int) string {
	if n <= 0 {
		n = 4
	}
	buf := make([]byte, n)
	if _, err := rand.Read(buf); err != nil {
		return fmt.Sprintf("%d", time.Now().UnixNano())
	}
	return hex.EncodeToString(buf)
}
