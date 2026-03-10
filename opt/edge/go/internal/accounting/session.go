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

type UsernameResolver func() string

type SSHRuntimeSessionTracker struct {
	logger     *log.Logger
	cfg        SSHQuotaConfig
	localPort  int
	clientIP   string
	transport  string
	resolver   UsernameResolver
	heartbeat  time.Duration
	sessionID  string
	done       chan struct{}
	onceStart  sync.Once
	onceStop   sync.Once
	activeFile string
}

func NewSSHRuntimeSessionTracker(logger *log.Logger, cfg SSHQuotaConfig, localPort int, clientIP, transport string, resolver UsernameResolver) *SSHRuntimeSessionTracker {
	if cfg.SessionRoot == "" || cfg.SessionHeartbeat <= 0 {
		return nil
	}
	return &SSHRuntimeSessionTracker{
		logger:    logger,
		cfg:       cfg,
		localPort: localPort,
		clientIP:  normalizeSessionIP(clientIP),
		transport: strings.TrimSpace(transport),
		resolver:  resolver,
		heartbeat: cfg.SessionHeartbeat,
		sessionID: fmt.Sprintf("edge-%d-%d-%s", os.Getpid(), localPort, randomHex(4)),
		done:      make(chan struct{}),
	}
}

func (t *SSHRuntimeSessionTracker) Start() {
	if t == nil {
		return
	}
	t.onceStart.Do(func() {
		go t.run()
	})
}

func (t *SSHRuntimeSessionTracker) Stop() {
	if t == nil {
		return
	}
	t.onceStop.Do(func() {
		close(t.done)
		if t.activeFile != "" {
			_ = os.Remove(t.activeFile)
			triggerEnforcer(t.logger, t.cfg.EnforcerPath)
		}
	})
}

func (t *SSHRuntimeSessionTracker) run() {
	ticker := time.NewTicker(t.heartbeat)
	defer ticker.Stop()

	for {
		t.update()
		select {
		case <-t.done:
			return
		case <-ticker.C:
		}
	}
}

func (t *SSHRuntimeSessionTracker) update() {
	username := t.resolveUsername()
	if username == "" {
		return
	}
	if err := os.MkdirAll(t.cfg.SessionRoot, 0o750); err != nil {
		if t.logger != nil {
			t.logger.Printf("edge-mux session mkdir failed root=%s: %v", t.cfg.SessionRoot, err)
		}
		return
	}
	target := filepath.Join(t.cfg.SessionRoot, t.sessionID+".json")
	payload := map[string]any{
		"username":   username,
		"client_ip":  t.clientIP,
		"transport":  t.transport,
		"local_port": t.localPort,
		"proxy_pid":  os.Getpid(),
		"updated_at": time.Now().Unix(),
		"source":     "edge-mux",
	}
	if err := writeJSONAtomic(target, payload); err != nil {
		if t.logger != nil {
			t.logger.Printf("edge-mux session write failed file=%s: %v", target, err)
		}
		return
	}
	if err := os.Chmod(target, 0o600); err != nil && t.logger != nil {
		t.logger.Printf("edge-mux session chmod failed file=%s: %v", target, err)
	}
	if t.activeFile == "" {
		t.activeFile = target
		triggerEnforcer(t.logger, t.cfg.EnforcerPath)
	}
}

func (t *SSHRuntimeSessionTracker) resolveUsername() string {
	if t == nil {
		return ""
	}
	if t.resolver != nil {
		if user := normalizeUser(t.resolver()); user != "" {
			return user
		}
	}
	if t.localPort > 0 {
		user, err := ResolveSSHUsernameByLocalPort(t.cfg.DropbearUnit, t.localPort)
		if err == nil {
			return normalizeUser(user)
		}
		if err != nil && t.logger != nil {
			t.logger.Printf("edge-mux session resolve failed port=%d: %v", t.localPort, err)
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
