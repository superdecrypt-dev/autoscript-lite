package main

import (
	"bufio"
	"context"
	"encoding/json"
	"errors"
	"flag"
	"fmt"
	"log"
	"net"
	"os"
	"os/exec"
	"os/signal"
	"path/filepath"
	"strconv"
	"strings"
	"sync"
	"syscall"
	"time"

	"github.com/superdecrypt-dev/autoscript/opt/edge/go/internal/detect"
	"github.com/superdecrypt-dev/autoscript/opt/edge/go/internal/wsproxy"
)

const handshakeTimeoutDefault = 10 * time.Second

const (
	policyCacheTTL     = 2 * time.Second
	policyStaleGrace   = 10 * time.Second
	controlErrorReason = "Service Unavailable"
	admissionTimeout   = 3 * time.Second
	policyTimeout      = 2 * time.Second
	sessionOpTimeout   = 2 * time.Second
	diagnosticProbeTok = "diagnostic-probe"
	diagnosticProbeUsr = "xray-ws-diagnostic"
	quotaFlushSignal   = syscall.SIGUSR1
)

type config struct {
	mode                 string
	listenHost           string
	listenPort           int
	backendHost          string
	backendPort          int
	sharedBackendHost  string
	sharedBackendPort  int
	sharedProbeTimeout time.Duration
	path                 string
	handshakeTimeout     time.Duration
	xrayStateRoot        string
	xrayLockFile         string
	xrayEnforcerBin      string
	xraySessionRoot      string
	controlBin           string
	quotaFlushInterval   time.Duration
}

type policy struct {
	Username     string `json:"username"`
	Blocked      bool   `json:"blocked"`
	SpeedEnabled bool   `json:"speed_enabled"`
	SpeedDownBPS int64  `json:"speed_down_bps"`
	SpeedUpBPS   int64  `json:"speed_up_bps"`
}

type admissionResponse struct {
	Allowed  bool    `json:"allowed"`
	Reason   string  `json:"reason"`
	Username string  `json:"username"`
	Policy   *policy `json:"policy"`
}

type policyResponse struct {
	Policy *policy `json:"policy"`
}

type controlOKResponse struct {
	OK bool `json:"ok"`
}

type reservation struct {
	user string
	ip   string
}

type connectionRegistry struct {
	mu            sync.Mutex
	pendingTotals map[string]int
	pendingIPs    map[string]map[string]int
	userLocks     sync.Map
}

func newConnectionRegistry() *connectionRegistry {
	return &connectionRegistry{
		pendingTotals: map[string]int{},
		pendingIPs:    map[string]map[string]int{},
	}
}

func (r *connectionRegistry) pendingSnapshot(user string) (int, []string) {
	total := r.pendingTotals[user]
	var ips []string
	for ip := range r.pendingIPs[user] {
		ips = append(ips, ip)
	}
	return total, ips
}

func (r *connectionRegistry) reserve(user, ip string) *reservation {
	res := &reservation{user: user, ip: ip}
	r.pendingTotals[user]++
	if ip != "" {
		if r.pendingIPs[user] == nil {
			r.pendingIPs[user] = map[string]int{}
		}
		r.pendingIPs[user][ip]++
	}
	return res
}

func (r *connectionRegistry) release(res *reservation) {
	if res == nil || res.user == "" {
		return
	}
	if cur := r.pendingTotals[res.user]; cur > 1 {
		r.pendingTotals[res.user] = cur - 1
	} else {
		delete(r.pendingTotals, res.user)
	}
	if res.ip != "" {
		if ipMap := r.pendingIPs[res.user]; ipMap != nil {
			if cur := ipMap[res.ip]; cur > 1 {
				ipMap[res.ip] = cur - 1
			} else {
				delete(ipMap, res.ip)
			}
			if len(ipMap) == 0 {
				delete(r.pendingIPs, res.user)
			}
		}
	}
}

func (r *connectionRegistry) reserveAdmission(ip string, ctl *controlClient, path, expectedPrefix string) (*admissionResponse, *reservation, error) {
	ip = wsproxy.NormalizeIP(ip)
	initial, err := ctl.admission(path, expectedPrefix, ip, 0, nil)
	if err != nil || initial == nil {
		return initial, nil, err
	}
	user := wsproxy.NormUser(initial.Username)
	if user == "" || !initial.Allowed || initial.Policy == nil {
		return initial, nil, err
	}
	return r.admitAndReserve(user, ip, func(extraTotal int, extraIPs []string) (*admissionResponse, error) {
		return ctl.admission(path, expectedPrefix, ip, extraTotal, extraIPs)
	})
}

func (r *connectionRegistry) userLock(user string) *sync.Mutex {
	user = wsproxy.NormUser(user)
	lock, _ := r.userLocks.LoadOrStore(user, &sync.Mutex{})
	return lock.(*sync.Mutex)
}

func (r *connectionRegistry) admitAndReserve(user, ip string, evaluate func(extraTotal int, extraIPs []string) (*admissionResponse, error)) (*admissionResponse, *reservation, error) {
	user = wsproxy.NormUser(user)
	ip = wsproxy.NormalizeIP(ip)
	lock := r.userLock(user)
	lock.Lock()
	defer lock.Unlock()
	r.mu.Lock()
	extraTotal, extraIPs := r.pendingSnapshot(user)
	r.mu.Unlock()
	finalResp, err := evaluate(extraTotal, extraIPs)
	if err != nil || finalResp == nil || !finalResp.Allowed || finalResp.Policy == nil {
		return finalResp, nil, err
	}
	r.mu.Lock()
	defer r.mu.Unlock()
	res := r.reserve(user, ip)
	return finalResp, res, nil
}

func (r *connectionRegistry) finalize(res *reservation) {
	if res == nil {
		return
	}
	r.mu.Lock()
	r.release(res)
	r.mu.Unlock()
}

type controlClient struct {
	bin         string
	stateRoot   string
	sessionRoot string
}

func (c *controlClient) runJSON(timeout time.Duration, args []string, out interface{}) error {
	ctx, cancel := context.WithTimeout(context.Background(), timeout)
	defer cancel()
	cmd := exec.CommandContext(ctx, c.bin, args...)
	data, err := cmd.CombinedOutput()
	if err != nil {
		if ctx.Err() != nil {
			return ctx.Err()
		}
		msg := strings.TrimSpace(string(data))
		if msg != "" {
			return fmt.Errorf("%w: %s", err, msg)
		}
		return err
	}
	return json.Unmarshal(data, out)
}

func (c *controlClient) admission(path, expectedPrefix, clientIP string, extraTotal int, extraIPs []string) (*admissionResponse, error) {
	args := []string{
		"admission",
		"--path", path,
		"--expected-prefix", expectedPrefix,
		"--state-root", c.stateRoot,
		"--session-root", c.sessionRoot,
		"--client-ip", clientIP,
		"--extra-total", strconv.Itoa(extraTotal),
		"--extra-client-ips", strings.Join(extraIPs, ","),
	}
	var out admissionResponse
	if err := c.runJSON(admissionTimeout, args, &out); err != nil {
		return nil, err
	}
	return &out, nil
}

func (c *controlClient) getPolicy(username string) (*policy, error) {
	args := []string{"policy", "--username", username, "--state-root", c.stateRoot}
	var out policyResponse
	if err := c.runJSON(policyTimeout, args, &out); err != nil {
		return nil, err
	}
	return out.Policy, nil
}

func (c *controlClient) sessionWrite(backendLocalPort int, backendTarget, username, clientIP string, proxyPID int) error {
	args := []string{
		"session-write",
		"--session-root", c.sessionRoot,
		"--backend-local-port", strconv.Itoa(backendLocalPort),
		"--backend-target", backendTarget,
		"--username", username,
		"--client-ip", clientIP,
		"--proxy-pid", strconv.Itoa(proxyPID),
	}
	var out controlOKResponse
	if err := c.runJSON(sessionOpTimeout, args, &out); err != nil {
		return err
	}
	if !out.OK {
		return errors.New("session-write rejected")
	}
	return nil
}

func (c *controlClient) sessionTouch(backendLocalPort int) error {
	args := []string{
		"session-touch",
		"--session-root", c.sessionRoot,
		"--backend-local-port", strconv.Itoa(backendLocalPort),
	}
	var out controlOKResponse
	if err := c.runJSON(sessionOpTimeout, args, &out); err != nil {
		return err
	}
	if !out.OK {
		return errors.New("session-touch rejected")
	}
	return nil
}

func (c *controlClient) sessionClear(backendLocalPort int) error {
	args := []string{
		"session-clear",
		"--session-root", c.sessionRoot,
		"--backend-local-port", strconv.Itoa(backendLocalPort),
	}
	var out controlOKResponse
	if err := c.runJSON(sessionOpTimeout, args, &out); err != nil {
		return err
	}
	if !out.OK {
		return errors.New("session-clear rejected")
	}
	return nil
}

type quotaRecorder struct {
	stateRoot   string
	lockFile    string
	enforcerBin string

	pending   map[string]int64
	pendingMu sync.Mutex
}

type quotaState struct {
	QuotaUsed int64 `json:"quota_used"`
}

func newQuotaRecorder(stateRoot, lockFile, enforcerBin string) *quotaRecorder {
	return &quotaRecorder{
		stateRoot:   stateRoot,
		lockFile:    lockFile,
		enforcerBin: enforcerBin,
		pending:     map[string]int64{},
	}
}

func (q *quotaRecorder) statePath(username string) string {
	user := wsproxy.NormUser(username)
	if user == "" {
		return filepath.Join(q.stateRoot, "@xray.json")
	}
	primary := filepath.Join(q.stateRoot, user+".json")
	return primary
}

func (q *quotaRecorder) loadState(path string) (map[string]any, error) {
	data, err := osReadFile(path)
	if err != nil {
		return nil, err
	}
	var st map[string]any
	if err := json.Unmarshal(data, &st); err != nil {
		return nil, err
	}
	return st, nil
}

func (q *quotaRecorder) record(username string, upBytes, downBytes int64) {
	user := wsproxy.NormUser(username)
	total := max64(upBytes, 0) + max64(downBytes, 0)
	if user == "" || total <= 0 {
		return
	}
	q.pendingMu.Lock()
	q.pending[user] += total
	q.pendingMu.Unlock()
}

func (q *quotaRecorder) flushOnce() error {
	q.pendingMu.Lock()
	if len(q.pending) == 0 {
		q.pendingMu.Unlock()
		return nil
	}
	deltas := q.pending
	q.pending = map[string]int64{}
	q.pendingMu.Unlock()

	if err := osMkdirAll(filepath.Dir(q.lockFile), 0700); err != nil {
		return err
	}
	lockh, err := osOpenFile(q.lockFile)
	if err != nil {
		return err
	}
	defer lockh.Close()
	if err := flock(lockh); err != nil {
		return err
	}
	defer funlock(lockh)

	changed := false
	for user, delta := range deltas {
		if delta <= 0 {
			continue
		}
		path := q.statePath(user)
		if !wsproxy.FileExists(path) {
			continue
		}
		st, err := q.loadState(path)
		if err != nil {
			continue
		}
		oldUsed := int64(wsproxy.ToInt(st["quota_used"]))
		newUsed := oldUsed + delta
		if newUsed == oldUsed {
			continue
		}
		st["quota_used"] = newUsed
		if err := wsproxy.WriteJSONAtomic(path, st, 0600); err != nil {
			continue
		}
		changed = true
	}
	if changed {
		triggerEnforcerAsync(q.enforcerBin, "")
	}
	return nil
}

type connectionContext struct {
	backendLocalPort int
	backendTarget    string
	clientIP         string
	username         string
	ctl              *controlClient
	recorder         *quotaRecorder

	mu             sync.Mutex
	pendingUp      int64
	pendingDown    int64
	policy         *policy
	policyCachedAt time.Time
}

func newConnectionContext(backendLocalPort int, backendTarget, clientIP, username string, ctl *controlClient, recorder *quotaRecorder) *connectionContext {
	ctx := &connectionContext{
		backendLocalPort: backendLocalPort,
		backendTarget:    backendTarget,
		clientIP:         clientIP,
		username:         username,
		ctl:              ctl,
		recorder:         recorder,
	}
	return ctx
}

func (c *connectionContext) setInitialPolicy(p *policy) {
	if p == nil {
		return
	}
	c.mu.Lock()
	c.policy = p
	c.policyCachedAt = time.Now()
	c.mu.Unlock()
}

func (c *connectionContext) writeRuntimeSession() error {
	return c.ctl.sessionWrite(c.backendLocalPort, c.backendTarget, c.username, c.clientIP, os.Getpid())
}

func (c *connectionContext) touchRuntimeSession(force bool) error {
	return c.ctl.sessionTouch(c.backendLocalPort)
}

func (c *connectionContext) clearRuntimeSession() error {
	return c.ctl.sessionClear(c.backendLocalPort)
}

func (c *connectionContext) currentPolicy() (*policy, error) {
	c.mu.Lock()
	if c.policy != nil && time.Since(c.policyCachedAt) < policyCacheTTL {
		p := c.policy
		c.mu.Unlock()
		return p, nil
	}
	c.mu.Unlock()
	p, err := c.ctl.getPolicy(c.username)
	if err != nil || p == nil {
		c.mu.Lock()
		cached := c.policy
		cachedAt := c.policyCachedAt
		c.mu.Unlock()
		if cached != nil && time.Since(cachedAt) < policyStaleGrace {
			return cached, nil
		}
		if err == nil {
			err = errors.New("policy unavailable")
		}
		return nil, err
	}
	c.mu.Lock()
	c.policy = p
	c.policyCachedAt = time.Now()
	c.mu.Unlock()
	return p, nil
}

func (c *connectionContext) recordUp(size int) {
	n := int64(maxInt(size, 0))
	if n <= 0 {
		return
	}
	c.recorder.record(c.username, n, 0)
}

func (c *connectionContext) recordDown(size int) {
	n := int64(maxInt(size, 0))
	if n <= 0 {
		return
	}
	c.recorder.record(c.username, 0, n)
}

func isLoopbackIP(value string) bool {
	ip := net.ParseIP(strings.TrimSpace(value))
	return ip != nil && ip.IsLoopback()
}

func isDiagnosticProbePath(pathOnly, expectedPrefix string) bool {
	rawPath := strings.SplitN(strings.SplitN(strings.TrimSpace(pathOnly), "?", 2)[0], "#", 2)[0]
	if rawPath == "" {
		rawPath = "/"
	}
	prefix := strings.SplitN(strings.SplitN(strings.TrimSpace(expectedPrefix), "?", 2)[0], "#", 2)[0]
	prefix = strings.TrimRight(prefix, "/")
	if prefix == "" {
		prefix = "/"
	}
	if prefix == "/" {
		return rawPath == "/"+diagnosticProbeTok
	}
	return rawPath == prefix+"/"+diagnosticProbeTok
}

func handleClient(conn net.Conn, cfg *config, registry *connectionRegistry, ctl *controlClient, recorder *quotaRecorder, limiter *wsproxy.RateLimiter) {
	defer conn.Close()
	wsr := bufio.NewReader(conn)
	wsw := wsproxy.NewWSWriter(conn)

	headers, pathOnly, accept, err := wsproxy.ReadHandshake(conn, cfg.handshakeTimeout, cfg.path)
	if err != nil {
		if hs, ok := err.(*wsproxy.HandshakeError); ok {
			wsproxy.SendHTTPError(conn, hs.Code, hs.Reason)
			return
		}
		wsproxy.SendHTTPError(conn, 400, "Bad Request")
		return
	}

	clientIP := wsproxy.ExtractClientIP(headers, conn)
	probeOnly := cfg.mode == "xray" && isLoopbackIP(clientIP) && isDiagnosticProbePath(pathOnly, cfg.path)
	sharedBackendEnabled := cfg.mode == "xray" && cfg.sharedBackendPort > 0

	var username string
	var res *reservation
	var resp *admissionResponse
	if cfg.mode == "xray" && !probeOnly {
		admission, reservation, err := registry.reserveAdmission(clientIP, ctl, pathOnly, cfg.path)
		if err != nil {
			log.Printf("xray-ws admission helper failed for %q from %q: %v", pathOnly, clientIP, err)
			wsproxy.SendHTTPError(conn, 503, controlErrorReason)
			return
		}
		resp = admission
		if !resp.Allowed {
			reason := resp.Reason
			if reason == "" {
				reason = "Forbidden"
			}
			code := 403
			if reason == "Unauthorized" {
				code = 401
			}
			wsproxy.SendHTTPError(conn, code, reason)
			return
		}
		username = resp.Username
		if wsproxy.NormUser(username) == diagnosticProbeUsr {
			if reservation != nil {
				registry.finalize(reservation)
			}
			reservation = nil
			probeOnly = true
		}
		if reservation != nil {
			reservation.user = username
		}
		res = reservation
	}

	backendHost := cfg.backendHost
	backendPort := cfg.backendPort
	var firstClientFrame *wsproxy.WSFrame
	xrayRuntime := cfg.mode == "xray" && !probeOnly
	if sharedBackendEnabled {
		if err := wsproxy.SendHandshakeOK(conn, accept); err != nil {
			if res != nil {
				registry.finalize(res)
			}
			return
		}
		frame, routeToSharedBackend, err := sniffInitialClientRoute(conn, wsr, wsw, cfg.sharedProbeTimeout)
		if err != nil {
			if res != nil {
				registry.finalize(res)
			}
			_ = wsw.WriteClose()
			return
		}
		firstClientFrame = frame
		if routeToSharedBackend {
			backendHost = cfg.sharedBackendHost
			backendPort = cfg.sharedBackendPort
			xrayRuntime = false
		}
	}

	backendConn, err := net.Dial("tcp", net.JoinHostPort(backendHost, strconv.Itoa(backendPort)))
	if err != nil {
		if res != nil {
			registry.finalize(res)
		}
		_ = wsw.WriteClose()
		return
	}
	defer backendConn.Close()

	var ctx *connectionContext
	if xrayRuntime {
		localPort := 0
		if addr, ok := backendConn.LocalAddr().(*net.TCPAddr); ok {
			localPort = addr.Port
		}
		ctx = newConnectionContext(localPort, net.JoinHostPort(backendHost, strconv.Itoa(backendPort)), clientIP, username, ctl, recorder)
		ctx.setInitialPolicy(resp.Policy)
		if err := ctx.writeRuntimeSession(); err != nil {
			registry.finalize(res)
			log.Printf("xray-ws session-write failed for user=%q port=%d: %v", username, localPort, err)
			_ = wsw.WriteClose()
			return
		}
		registry.finalize(res)
		defer func() {
			if ctx != nil {
				_ = recorder.flushOnce()
				if err := ctx.clearRuntimeSession(); err != nil {
					log.Printf("xray-ws session-clear failed for user=%q port=%d: %v", username, localPort, err)
				}
				triggerEnforcerAsync(cfg.xrayEnforcerBin, username)
			}
		}()
	} else if res != nil {
		registry.finalize(res)
	}

	if !sharedBackendEnabled {
		if err := wsproxy.SendHandshakeOK(conn, accept); err != nil {
			return
		}
	}

	if cfg.mode == "xray" && username != "" && xrayRuntime {
		triggerEnforcerAsync(cfg.xrayEnforcerBin, username)
	}

	done := make(chan struct{}, 2)
	if ctx != nil {
		stop := make(chan struct{})
		defer close(stop)
		go func() {
			ticker := time.NewTicker(wsproxy.RuntimeSessionHeartbeat)
			defer ticker.Stop()
			for {
				select {
				case <-ticker.C:
					if err := ctx.touchRuntimeSession(true); err != nil {
						log.Printf("xray-ws session-touch failed for user=%q port=%d: %v", username, ctx.backendLocalPort, err)
						_ = backendConn.SetDeadline(time.Now())
						_ = conn.SetDeadline(time.Now())
						return
					}
				case <-stop:
					return
				}
			}
		}()
	}

	go func() {
		defer func() { done <- struct{}{} }()
		_ = pumpClientToBackend(wsr, wsw, backendConn, ctx, limiter, firstClientFrame)
		_ = backendConn.SetDeadline(time.Now())
	}()
	go func() {
		defer func() { done <- struct{}{} }()
		_ = pumpBackendToClient(backendConn, wsw, ctx, limiter)
		_ = conn.SetDeadline(time.Now())
	}()
	<-done
	_ = wsw.WriteClose()
}

func writeFrameToBackend(frame *wsproxy.WSFrame, wsw *wsproxy.WSWriter, backend net.Conn, ctx *connectionContext, limiter *wsproxy.RateLimiter) error {
	if frame == nil {
		return nil
	}
	switch frame.Opcode {
	case wsproxy.OpPing:
		return wsw.WritePong(frame.Payload)
	case wsproxy.OpPong:
		return nil
	case wsproxy.OpClose:
		return context.Canceled
	case wsproxy.OpBinary, wsproxy.OpText, wsproxy.OpContinuation:
	default:
		return nil
	}
	if ctx != nil {
		pol, err := ctx.currentPolicy()
		if err != nil {
			return context.Canceled
		}
		if pol != nil {
			if pol.Blocked {
				return context.Canceled
			}
			if pol.SpeedEnabled {
				limiter.Throttle(pol.Username, "up", len(frame.Payload), pol.SpeedUpBPS)
			}
		}
		ctx.recordUp(len(frame.Payload))
	}
	if len(frame.Payload) == 0 {
		return nil
	}
	_, err := backend.Write(frame.Payload)
	return err
}

func pumpClientToBackend(r *bufio.Reader, wsw *wsproxy.WSWriter, backend net.Conn, ctx *connectionContext, limiter *wsproxy.RateLimiter, firstFrame *wsproxy.WSFrame) error {
	if err := writeFrameToBackend(firstFrame, wsw, backend, ctx, limiter); err != nil {
		return err
	}
	for {
		frame, err := wsproxy.ReadWSFrame(r)
		if err != nil {
			return err
		}
		if err := writeFrameToBackend(frame, wsw, backend, ctx, limiter); err != nil {
			return err
		}
	}
}

func pumpBackendToClient(backend net.Conn, wsw *wsproxy.WSWriter, ctx *connectionContext, limiter *wsproxy.RateLimiter) error {
	buf := make([]byte, 16384)
	for {
		n, err := backend.Read(buf)
		if n > 0 {
			payload := append([]byte(nil), buf[:n]...)
			if ctx != nil {
				pol, err := ctx.currentPolicy()
				if err != nil {
					return context.Canceled
				}
				if pol != nil {
					if pol.Blocked {
						return context.Canceled
					}
					if pol.SpeedEnabled {
						limiter.Throttle(pol.Username, "down", len(payload), pol.SpeedDownBPS)
					}
				}
				ctx.recordDown(len(payload))
			}
			if err := wsw.WriteBinary(payload); err != nil {
				return err
			}
		}
		if err != nil {
			return err
		}
	}
}

func quotaFlushLoop(ctx context.Context, recorder *quotaRecorder, interval time.Duration) {
	ticker := time.NewTicker(interval)
	defer ticker.Stop()
	for {
		select {
		case <-ctx.Done():
			return
		case <-ticker.C:
			_ = recorder.flushOnce()
		}
	}
}

func quotaFlushSignalLoop(ctx context.Context, recorder *quotaRecorder, logger *log.Logger) {
	sigCh := make(chan os.Signal, 1)
	signal.Notify(sigCh, quotaFlushSignal)
	defer signal.Stop(sigCh)
	for {
		select {
		case <-ctx.Done():
			return
		case <-sigCh:
			if err := recorder.flushOnce(); err != nil && logger != nil {
				logger.Printf("xray-ws quota flush via signal failed: %v", err)
			}
		}
	}
}

func run(cfg *config) error {
	lc := net.ListenConfig{}
	ln, err := lc.Listen(context.Background(), "tcp", net.JoinHostPort(cfg.listenHost, strconv.Itoa(cfg.listenPort)))
	if err != nil {
		return err
	}
	defer ln.Close()

	ctx, stop := signal.NotifyContext(context.Background(), syscall.SIGINT, syscall.SIGTERM)
	defer stop()

	registry := newConnectionRegistry()
	limiter := wsproxy.NewRateLimiter()
	control := &controlClient{bin: cfg.controlBin, stateRoot: cfg.xrayStateRoot, sessionRoot: cfg.xraySessionRoot}
	recorder := newQuotaRecorder(cfg.xrayStateRoot, cfg.xrayLockFile, cfg.xrayEnforcerBin)
	if cfg.mode == "xray" {
		go quotaFlushLoop(ctx, recorder, cfg.quotaFlushInterval)
		go quotaFlushSignalLoop(ctx, recorder, log.Default())
	}

	var wg sync.WaitGroup
	go func() {
		<-ctx.Done()
		_ = ln.Close()
	}()

	for {
		conn, err := ln.Accept()
		if err != nil {
			if ctx.Err() != nil {
				break
			}
			continue
		}
		wg.Add(1)
		go func(c net.Conn) {
			defer wg.Done()
			handleClient(c, cfg, registry, control, recorder, limiter)
		}(conn)
	}
	wg.Wait()
	_ = recorder.flushOnce()
	return nil
}

func parseArgs() *config {
	cfg := &config{}
	flag.StringVar(&cfg.mode, "mode", "xray", "Proxy mode: xray or tcp")
	flag.StringVar(&cfg.listenHost, "listen-host", "127.0.0.1", "Listen host")
	flag.IntVar(&cfg.listenPort, "listen-port", 10015, "Listen port")
	flag.StringVar(&cfg.backendHost, "backend-host", "127.0.0.1", "Backend host")
	flag.IntVar(&cfg.backendPort, "backend-port", 18080, "Backend port")
	flag.StringVar(&cfg.sharedBackendHost, "shared-backend-host", "127.0.0.1", "Shared backend host for TLS-like WS payloads")
	flag.IntVar(&cfg.sharedBackendPort, "shared-backend-port", 0, "Optional shared backend port for shared WS path")
	flag.StringVar(&cfg.path, "path", "/", "Expected public path prefix")
	var hsTimeout float64
	flag.Float64Var(&hsTimeout, "handshake-timeout", handshakeTimeoutDefault.Seconds(), "Handshake timeout in seconds")
	var sharedProbeMS int
	flag.IntVar(&sharedProbeMS, "shared-probe-timeout-ms", 250, "Timeout in milliseconds to wait for initial shared-backend payload after WS upgrade")
	flag.StringVar(&cfg.xrayStateRoot, "xray-state-root", "/opt/quota/xray", "Xray quota state root")
	flag.StringVar(&cfg.xrayLockFile, "xray-lock-file", "/run/autoscript/locks/xray-ws-qac.lock", "Xray quota lock file")
	flag.StringVar(&cfg.xrayEnforcerBin, "xray-enforcer-bin", "/usr/local/bin/true", "Xray quota enforcer binary")
	flag.StringVar(&cfg.xraySessionRoot, "xray-session-root", "/run/autoscript/xray-ws-sessions", "Runtime session root")
	flag.StringVar(&cfg.controlBin, "control-bin", "/usr/local/bin/xray-ws-control", "Python control plane helper")
	var flushInt float64
	flag.Float64Var(&flushInt, "quota-flush-interval", 1.0, "Quota flush interval in seconds")
	flag.Parse()
	cfg.handshakeTimeout = time.Duration(hsTimeout * float64(time.Second))
	if cfg.handshakeTimeout <= 0 {
		cfg.handshakeTimeout = handshakeTimeoutDefault
	}
	cfg.quotaFlushInterval = time.Duration(flushInt * float64(time.Second))
	if cfg.quotaFlushInterval < time.Second {
		cfg.quotaFlushInterval = time.Second
	}
	switch strings.ToLower(strings.TrimSpace(cfg.mode)) {
	case "xray":
		cfg.mode = "xray"
	default:
		cfg.mode = "tcp"
	}
	if sharedProbeMS < 0 {
		sharedProbeMS = 0
	}
	cfg.sharedProbeTimeout = time.Duration(sharedProbeMS) * time.Millisecond
	return cfg
}

func sniffInitialClientRoute(conn net.Conn, reader *bufio.Reader, writer *wsproxy.WSWriter, timeout time.Duration) (*wsproxy.WSFrame, bool, error) {
	if timeout <= 0 {
		return nil, false, nil
	}
	_ = conn.SetReadDeadline(time.Now().Add(timeout))
	defer conn.SetReadDeadline(time.Time{})
	for {
		frame, err := wsproxy.ReadWSFrame(reader)
		if err != nil {
			if ne, ok := err.(net.Error); ok && ne.Timeout() {
				return nil, false, nil
			}
			return nil, false, err
		}
		switch frame.Opcode {
		case wsproxy.OpPing:
			if err := writer.WritePong(frame.Payload); err != nil {
				return nil, false, err
			}
			continue
		case wsproxy.OpPong:
			continue
		case wsproxy.OpClose:
			return frame, false, context.Canceled
		case wsproxy.OpBinary, wsproxy.OpText, wsproxy.OpContinuation:
			routeToSharedBackend := detect.IsTLSClientHello(frame.Payload)
			return frame, routeToSharedBackend, nil
		default:
			continue
		}
	}
}

func main() {
	cfg := parseArgs()
	log.SetFlags(log.LstdFlags | log.Lmicroseconds)
	if err := run(cfg); err != nil {
		log.Fatal(err)
	}
}

func osReadFile(path string) ([]byte, error) { return os.ReadFile(path) }

func osMkdirAll(path string, mode uint32) error { return os.MkdirAll(path, os.FileMode(mode)) }

func osOpenFile(path string) (*os.File, error) { return os.OpenFile(path, os.O_CREATE|os.O_RDWR, 0600) }

func flock(f *os.File) error { return syscall.Flock(int(f.Fd()), syscall.LOCK_EX) }

func funlock(f *os.File) error { return syscall.Flock(int(f.Fd()), syscall.LOCK_UN) }

func triggerEnforcer(bin, user string) error {
	if bin == "" || !wsproxy.FileExecutable(bin) {
		return nil
	}
	args := []string{"--once"}
	if u := wsproxy.NormUser(user); u != "" {
		args = append(args, "--user", u)
	}
	cmd := exec.Command(bin, args...)
	cmd.Stdout = nil
	cmd.Stderr = nil
	if err := cmd.Start(); err != nil {
		return err
	}
	done := make(chan error, 1)
	go func() { done <- cmd.Wait() }()
	select {
	case err := <-done:
		return err
	case <-time.After(10 * time.Second):
		_ = cmd.Process.Kill()
		<-done
		return context.DeadlineExceeded
	}
}

func triggerEnforcerAsync(bin, user string) {
	go func() {
		if err := triggerEnforcer(bin, user); err != nil {
			log.Printf("xray-ws trigger-enforcer failed for user=%q: %v", wsproxy.NormUser(user), err)
		}
	}()
}

func maxInt(a, b int) int {
	if a > b {
		return a
	}
	return b
}

func max64(a, b int64) int64 {
	if a > b {
		return a
	}
	return b
}
