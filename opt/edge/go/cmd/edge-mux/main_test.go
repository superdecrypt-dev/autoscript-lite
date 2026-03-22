package main

import (
	"context"
	"errors"
	"net"
	"sync"
	"testing"
	"time"

	"github.com/superdecrypt-dev/autoscript/opt/edge/go/internal/detect"
	"github.com/superdecrypt-dev/autoscript/opt/edge/go/internal/observability"
	"github.com/superdecrypt-dev/autoscript/opt/edge/go/internal/runtime"
)

func TestReportFatalErrorSendsOnlyFirstError(t *testing.T) {
	errCh := make(chan error, 1)
	var once sync.Once

	reportFatalError(errCh, &once, "first", errors.New("one"))
	reportFatalError(errCh, &once, "second", errors.New("two"))

	select {
	case err := <-errCh:
		if got := err.Error(); got != "first: one" {
			t.Fatalf("reported error = %q, want %q", got, "first: one")
		}
	default:
		t.Fatalf("expected first fatal error to be reported")
	}

	select {
	case err := <-errCh:
		t.Fatalf("unexpected extra fatal error reported: %v", err)
	default:
	}
}

func TestReportFatalErrorDoesNotBlockWhenChannelAlreadyFull(t *testing.T) {
	errCh := make(chan error, 1)
	errCh <- errors.New("existing")
	var once sync.Once

	done := make(chan struct{})
	go func() {
		reportFatalError(errCh, &once, "late", errors.New("boom"))
		close(done)
	}()

	select {
	case <-done:
	case <-time.After(500 * time.Millisecond):
		t.Fatalf("reportFatalError blocked on full channel")
	}

	select {
	case err := <-errCh:
		if got := err.Error(); got != "existing" {
			t.Fatalf("channel value = %q, want existing", got)
		}
	default:
		t.Fatalf("expected original buffered error to remain")
	}
}

func TestReloadableListenerHealthyTracksClosedListener(t *testing.T) {
	addr := reserveTCPAddr(t)
	listener, err := newReloadableListener([]string{addr})
	if err != nil {
		t.Fatalf("newReloadableListener error = %v", err)
	}
	defer func() {
		_ = listener.Close()
	}()

	if !listener.Healthy() {
		t.Fatalf("Healthy() = false, want true immediately after start")
	}

	listener.mu.RLock()
	ln := listener.listeners[addr]
	listener.mu.RUnlock()
	if ln == nil {
		t.Fatalf("listener for %q = nil", addr)
	}
	if err := ln.Close(); err != nil {
		t.Fatalf("close listener error = %v", err)
	}

	waitForCondition(t, 2*time.Second, func() bool {
		return !listener.Healthy()
	})
	if got := listener.ActiveAddrs(); len(got) != 0 {
		t.Fatalf("ActiveAddrs() = %v, want empty after listener close", got)
	}
}

func TestReloadableListenerReconcileRevivesClosedListener(t *testing.T) {
	addr := reserveTCPAddr(t)
	listener, err := newReloadableListener([]string{addr})
	if err != nil {
		t.Fatalf("newReloadableListener error = %v", err)
	}
	defer func() {
		_ = listener.Close()
	}()

	listener.mu.RLock()
	oldListener := listener.listeners[addr]
	listener.mu.RUnlock()
	if oldListener == nil {
		t.Fatalf("listener for %q = nil", addr)
	}
	if err := oldListener.Close(); err != nil {
		t.Fatalf("close listener error = %v", err)
	}

	waitForCondition(t, 2*time.Second, func() bool {
		return !listener.Healthy()
	})
	if err := listener.Reconcile([]string{addr}); err != nil {
		t.Fatalf("Reconcile() error = %v", err)
	}
	if !listener.Healthy() {
		t.Fatalf("Healthy() = false after reconcile, want true")
	}

	listener.mu.RLock()
	newListener := listener.listeners[addr]
	listener.mu.RUnlock()
	if newListener == nil {
		t.Fatalf("listener for %q = nil after reconcile", addr)
	}
	if newListener == oldListener {
		t.Fatalf("listener was not recreated for %q", addr)
	}
}

func TestReloadableListenerReconcileClosesInactiveListenerBeforeRebind(t *testing.T) {
	addr := reserveTCPAddr(t)
	stale, err := net.Listen("tcp", addr)
	if err != nil {
		t.Fatalf("stale listen error = %v", err)
	}

	listener := &reloadableListener{
		listeners: map[string]net.Listener{addr: stale},
		active:    map[string]bool{addr: false},
		addrs:     []string{addr},
		acceptCh:  make(chan acceptResult, 1),
		closeCh:   make(chan struct{}),
	}
	defer func() {
		_ = listener.Close()
	}()

	if err := listener.Reconcile([]string{addr}); err != nil {
		t.Fatalf("Reconcile() error = %v", err)
	}
	if !listener.Healthy() {
		t.Fatalf("Healthy() = false after reconcile, want true")
	}

	listener.mu.RLock()
	newListener := listener.listeners[addr]
	listener.mu.RUnlock()
	if newListener == nil {
		t.Fatalf("listener for %q = nil after reconcile", addr)
	}
	if newListener == stale {
		t.Fatalf("inactive listener for %q was not replaced", addr)
	}
}

func TestReloadableListenerAcceptFailsWhenAllListenersInactive(t *testing.T) {
	listener := &reloadableListener{
		listeners: make(map[string]net.Listener),
		active:    map[string]bool{"127.0.0.1:1": false},
		addrs:     []string{"127.0.0.1:1"},
		acceptCh:  make(chan acceptResult, 1),
		closeCh:   make(chan struct{}),
	}

	ctx, cancel := context.WithTimeout(context.Background(), time.Second)
	defer cancel()

	_, err := listener.Accept(ctx)
	if !errors.Is(err, errNoActiveListeners) {
		t.Fatalf("Accept() error = %v, want %v", err, errNoActiveListeners)
	}
}

func TestIsRetryableAcceptErrorTreatsTemporaryAsRetryable(t *testing.T) {
	if !isRetryableAcceptError(temporaryAcceptError{}) {
		t.Fatalf("isRetryableAcceptError() = false, want true for temporary error")
	}
}

func TestReloadableListenerMarksNonRetryableAcceptErrorInactive(t *testing.T) {
	listener := &reloadableListener{
		listeners: make(map[string]net.Listener),
		active:    make(map[string]bool),
		acceptCh:  make(chan acceptResult, 1),
		closeCh:   make(chan struct{}),
	}
	addr := "127.0.0.1:1"
	ln := &scriptedListener{acceptErr: errors.New("boom")}
	listener.listeners[addr] = ln
	listener.addrs = []string{addr}
	listener.active[addr] = true

	listener.serveAcceptLoop(addr, ln)

	waitForCondition(t, 2*time.Second, func() bool {
		return !listener.Healthy()
	})
	if got := listener.ActiveAddrs(); len(got) != 0 {
		t.Fatalf("ActiveAddrs() = %v, want empty after non-retryable accept error", got)
	}
}

func reserveTCPAddr(t *testing.T) string {
	t.Helper()
	ln, err := net.Listen("tcp", "127.0.0.1:0")
	if err != nil {
		t.Fatalf("reserveTCPAddr listen error = %v", err)
	}
	addr := ln.Addr().String()
	if err := ln.Close(); err != nil {
		t.Fatalf("reserveTCPAddr close error = %v", err)
	}
	return addr
}

func waitForCondition(t *testing.T, timeout time.Duration, cond func() bool) {
	t.Helper()
	deadline := time.Now().Add(timeout)
	for time.Now().Before(deadline) {
		if cond() {
			return
		}
		time.Sleep(10 * time.Millisecond)
	}
	t.Fatalf("condition not met within %s", timeout)
}

type scriptedListener struct {
	acceptErr error
	closed    bool
}

func (l *scriptedListener) Accept() (net.Conn, error) { return nil, l.acceptErr }
func (l *scriptedListener) Close() error {
	l.closed = true
	return nil
}
func (l *scriptedListener) Addr() net.Addr { return dummyTCPAddr("127.0.0.1:1") }

type dummyTCPAddr string

func (a dummyTCPAddr) Network() string { return "tcp" }
func (a dummyTCPAddr) String() string  { return string(a) }

var _ net.Listener = (*scriptedListener)(nil)
var _ net.Addr = dummyTCPAddr("")

type temporaryAcceptError struct{}

func (temporaryAcceptError) Error() string   { return "temporary" }
func (temporaryAcceptError) Temporary() bool { return true }

func TestDecideHTTPRouteUnauthorizedForUnknownWebSocket(t *testing.T) {
	cfg := runtime.Config{HTTPBackend: "127.0.0.1:18080"}
	initial := []byte("GET / HTTP/1.1\r\nHost: example.com\r\nUpgrade: websocket\r\nConnection: Upgrade\r\n\r\n")

	decision := decideHTTPRoute(cfg, "tls-inner", initial, "", "", false)

	if decision.Route != "websocket-other" {
		t.Fatalf("route = %q, want websocket-other", decision.Route)
	}
	if decision.Status != 401 {
		t.Fatalf("status = %d, want 401", decision.Status)
	}
	if decision.Text != "Unauthorized" {
		t.Fatalf("text = %q, want Unauthorized", decision.Text)
	}
}

func TestDecideHTTPRouteKnownSSHWebSocketPathPassesThrough(t *testing.T) {
	cfg := runtime.Config{HTTPBackend: "127.0.0.1:18080"}
	initial := []byte("GET /deadbeef00 HTTP/1.1\r\nHost: example.com\r\nUpgrade: websocket\r\nConnection: Upgrade\r\n\r\n")

	decision := decideHTTPRoute(cfg, "tls-inner", initial, "", "", false)

	if decision.Route != "ssh-ws-like" {
		t.Fatalf("route = %q, want ssh-ws-like", decision.Route)
	}
	if decision.Status != 0 {
		t.Fatalf("status = %d, want 0", decision.Status)
	}
}

func TestDecideHTTPRouteDiagnosticProbeRequiresLoopback(t *testing.T) {
	cfg := runtime.Config{HTTPBackend: "127.0.0.1:18080"}
	initial := []byte("GET /diagnostic-probe HTTP/1.1\r\nHost: example.com\r\nUpgrade: websocket\r\nConnection: Upgrade\r\n\r\n")

	blocked := decideHTTPRoute(cfg, "tls-inner", initial, "", "", false)
	if blocked.Route != "websocket-other" || blocked.Status != 401 {
		t.Fatalf("blocked diagnostic route = (%q,%d), want (websocket-other,401)", blocked.Route, blocked.Status)
	}

	allowed := decideHTTPRoute(cfg, "tls-inner", initial, "", "", true)
	if allowed.Route != "ssh-ws-like" || allowed.Status != 0 {
		t.Fatalf("allowed diagnostic route = (%q,%d), want (ssh-ws-like,0)", allowed.Route, allowed.Status)
	}
}

func TestRouteBlockedByHealthUsesSpecificBackendKey(t *testing.T) {
	cfg := runtime.Config{
		SSHBackend:       "127.0.0.1:22022",
		SSHTLSBackend:    "127.0.0.1:22443",
		SSHWSBackend:     "127.0.0.1:10015",
		VLESSRawBackend:  "127.0.0.1:33175",
		TrojanRawBackend: "127.0.0.1:48778",
	}
	health := &backendHealthState{}
	health.Set(map[string]observability.BackendHealthSnapshot{
		"ssh": {
			Address: "direct=127.0.0.1:22022, tls=127.0.0.1:22443, ws=127.0.0.1:10015",
			Healthy: false,
			Status:  "degraded",
		},
		"ssh-direct": {
			Address: "127.0.0.1:22022",
			Healthy: true,
			Status:  "up",
		},
	})

	if _, blocked := routeBlockedByHealth(health, cfg, cfg.SSHBackendAddr()); blocked {
		t.Fatalf("routeBlockedByHealth() = true, want false for healthy ssh-direct backend")
	}
}

func TestRouteDecisionEventUsesSpecificBackendStatus(t *testing.T) {
	cfg := runtime.Config{
		SSHBackend:       "127.0.0.1:22022",
		SSHTLSBackend:    "127.0.0.1:22443",
		SSHWSBackend:     "127.0.0.1:10015",
		VLESSRawBackend:  "127.0.0.1:33175",
		TrojanRawBackend: "127.0.0.1:48778",
	}
	health := &backendHealthState{}
	health.Set(map[string]observability.BackendHealthSnapshot{
		"vless": {
			Address: "127.0.0.1:33175",
			Healthy: false,
			Status:  "down",
		},
	})

	event := routeDecisionEvent(cfg, health, detect.ClassVLESSRaw, cfg.VLESSRawBackendAddr(), "vless-tcp", "", "", "", "", "", 0, "detect", "")
	if event.Backend != "vless" {
		t.Fatalf("Backend = %q, want vless", event.Backend)
	}
	if event.BackendStatus != "down" {
		t.Fatalf("BackendStatus = %q, want down", event.BackendStatus)
	}
}

func TestDecideTLSPayloadRouteUsesSNIOverride(t *testing.T) {
	cfg := runtime.Config{
		HTTPBackend:      "127.0.0.1:18080",
		SSHBackend:       "127.0.0.1:22022",
		SSHTLSBackend:    "127.0.0.1:22443",
		SSHWSBackend:     "127.0.0.1:10015",
		VLESSRawBackend:  "127.0.0.1:33175",
		TrojanRawBackend: "127.0.0.1:48778",
		SNIRoutes: map[string]string{
			"vmess.example.com": "vless_tcp",
		},
	}
	initial := []byte("GET / HTTP/1.1\r\nHost: vmess.example.com\r\nUpgrade: websocket\r\nConnection: Upgrade\r\n\r\n")

	decision := decideTLSPayloadRoute(cfg, "tls-inner", initial, detect.ClassHTTP, "http/1.1", "vmess.example.com", false)

	if decision.target != cfg.VLESSRawBackendAddr() {
		t.Fatalf("target = %q, want %q", decision.target, cfg.VLESSRawBackendAddr())
	}
	if decision.route != "sni-vless-tcp" {
		t.Fatalf("route = %q, want sni-vless-tcp", decision.route)
	}
	if decision.routeSource != "sni" {
		t.Fatalf("routeSource = %q, want sni", decision.routeSource)
	}
	if decision.matchedRoute != "vless_tcp" {
		t.Fatalf("matchedRoute = %q, want vless_tcp", decision.matchedRoute)
	}
	if decision.reason != "sni_match" {
		t.Fatalf("reason = %q, want sni_match", decision.reason)
	}
	if decision.host != "vmess.example.com" {
		t.Fatalf("host = %q, want vmess.example.com", decision.host)
	}
	if decision.path != "/" {
		t.Fatalf("path = %q, want /", decision.path)
	}
}

func TestDecideTLSPayloadRouteFallsBackWhenSNIMissing(t *testing.T) {
	cfg := runtime.Config{
		HTTPBackend:      "127.0.0.1:18080",
		SSHBackend:       "127.0.0.1:22022",
		VLESSRawBackend:  "127.0.0.1:33175",
		TrojanRawBackend: "127.0.0.1:48778",
	}
	initial := []byte("GET / HTTP/1.1\r\nHost: example.com\r\nUpgrade: websocket\r\nConnection: Upgrade\r\n\r\n")

	decision := decideTLSPayloadRoute(cfg, "tls-inner", initial, detect.ClassHTTP, "http/1.1", "unknown.example.com", false)

	if decision.target != cfg.HTTPBackendAddr() {
		t.Fatalf("target = %q, want %q", decision.target, cfg.HTTPBackendAddr())
	}
	if decision.route != "websocket-other" {
		t.Fatalf("route = %q, want websocket-other", decision.route)
	}
	if decision.routeSource != "detect" {
		t.Fatalf("routeSource = %q, want detect", decision.routeSource)
	}
	if decision.status != 401 {
		t.Fatalf("status = %d, want 401", decision.status)
	}
}

func TestResolveSNIRouteDecisionUsesConfiguredBackend(t *testing.T) {
	cfg := runtime.Config{
		HTTPBackend:      "127.0.0.1:18080",
		SSHBackend:       "127.0.0.1:22022",
		SSHTLSBackend:    "127.0.0.1:22443",
		SSHWSBackend:     "127.0.0.1:10015",
		VLESSRawBackend:  "127.0.0.1:33175",
		TrojanRawBackend: "127.0.0.1:48778",
		SNIRoutes: map[string]string{
			"vmess.example.com": "vless_tcp",
			"ws.example.com":    "ssh_ws",
		},
	}

	decision, ok := resolveSNIRouteDecision(cfg, "VMESS.EXAMPLE.COM", "tls-inner")
	if !ok {
		t.Fatalf("resolveSNIRouteDecision() ok = false, want true")
	}
	if decision.target != cfg.VLESSRawBackendAddr() {
		t.Fatalf("decision.target = %q, want %q", decision.target, cfg.VLESSRawBackendAddr())
	}
	if decision.route != "sni-vless-tcp" {
		t.Fatalf("decision.route = %q, want sni-vless-tcp", decision.route)
	}
	if decision.routeSource != "sni" {
		t.Fatalf("decision.routeSource = %q, want sni", decision.routeSource)
	}
	if decision.matchedRoute != "vless_tcp" {
		t.Fatalf("decision.matchedRoute = %q, want vless_tcp", decision.matchedRoute)
	}
	if decision.reason != "sni_match" {
		t.Fatalf("decision.reason = %q, want sni_match", decision.reason)
	}

	wsDecision, ok := resolveSNIRouteDecision(cfg, "ws.example.com", "tls-inner")
	if !ok {
		t.Fatalf("resolveSNIRouteDecision() ok = false, want true for ssh_ws route")
	}
	if wsDecision.target != cfg.SSHWSBackendAddr() {
		t.Fatalf("wsDecision.target = %q, want %q", wsDecision.target, cfg.SSHWSBackendAddr())
	}
	if wsDecision.matchedRoute != "ssh_ws" {
		t.Fatalf("wsDecision.matchedRoute = %q, want ssh_ws", wsDecision.matchedRoute)
	}
	if !wsDecision.sendHTTP502 {
		t.Fatalf("wsDecision.sendHTTP502 = false, want true")
	}
}

func TestResolveSNIPassthroughDecisionUsesConfiguredBackend(t *testing.T) {
	cfg := runtime.Config{
		SNIPassthrough: map[string]string{
			"vision.example.com": "127.0.0.1:8443",
		},
	}

	decision, ok := resolveSNIPassthroughDecision(cfg, "VISION.EXAMPLE.COM.", "tls-port")
	if !ok {
		t.Fatalf("resolveSNIPassthroughDecision() ok = false, want true")
	}
	if decision.target != "127.0.0.1:8443" {
		t.Fatalf("decision.target = %q, want 127.0.0.1:8443", decision.target)
	}
	if decision.route != "sni-passthrough" {
		t.Fatalf("decision.route = %q, want sni-passthrough", decision.route)
	}
	if decision.routeSource != "passthrough" {
		t.Fatalf("decision.routeSource = %q, want passthrough", decision.routeSource)
	}
	if decision.reason != "sni_passthrough" {
		t.Fatalf("decision.reason = %q, want sni_passthrough", decision.reason)
	}
	if decision.contextLabel != "tls-port:sni-passthrough" {
		t.Fatalf("decision.contextLabel = %q, want tls-port:sni-passthrough", decision.contextLabel)
	}
}

func TestBackendLabelUsesPassthroughForConfiguredTarget(t *testing.T) {
	cfg := runtime.Config{
		SNIPassthrough: map[string]string{
			"vision.example.com": "127.0.0.1:8443",
		},
	}

	if got := backendLabel(cfg, "127.0.0.1:8443"); got != "passthrough" {
		t.Fatalf("backendLabel() = %q, want passthrough", got)
	}
}

func TestUniquePassthroughTargetsDeduplicatesAndSorts(t *testing.T) {
	cfg := runtime.Config{
		SNIPassthrough: map[string]string{
			"b.example.com": "127.0.0.1:9443",
			"a.example.com": "127.0.0.1:8443",
			"c.example.com": "127.0.0.1:8443",
		},
	}

	got := uniquePassthroughTargets(cfg)
	if len(got) != 2 {
		t.Fatalf("len(uniquePassthroughTargets) = %d, want 2", len(got))
	}
	if got[0] != "127.0.0.1:8443" || got[1] != "127.0.0.1:9443" {
		t.Fatalf("uniquePassthroughTargets = %#v, want [127.0.0.1:8443 127.0.0.1:9443]", got)
	}
}

func TestBackendHealthSnapshotIncludesPassthroughTargets(t *testing.T) {
	cfg := runtime.Config{
		HTTPBackend:      "127.0.0.1:18080",
		SSHBackend:       "127.0.0.1:22022",
		SSHTLSBackend:    "127.0.0.1:22443",
		SSHWSBackend:     "127.0.0.1:10015",
		VLESSRawBackend:  "127.0.0.1:33175",
		TrojanRawBackend: "127.0.0.1:48778",
		SNIPassthrough: map[string]string{
			"vision.example.com": "127.0.0.1:18443",
		},
	}

	snapshot := backendHealthSnapshot(cfg)
	entry, ok := snapshot["passthrough:127.0.0.1:18443"]
	if !ok {
		t.Fatalf("backendHealthSnapshot missing passthrough backend entry")
	}
	if entry.Address != "127.0.0.1:18443" {
		t.Fatalf("passthrough Address = %q, want 127.0.0.1:18443", entry.Address)
	}
}

func TestDecideTLSPayloadRoutePrefersSNIToDetectedClass(t *testing.T) {
	cfg := runtime.Config{
		HTTPBackend:      "127.0.0.1:18080",
		SSHBackend:       "127.0.0.1:22022",
		VLESSRawBackend:  "127.0.0.1:33175",
		TrojanRawBackend: "127.0.0.1:48778",
		SNIRoutes: map[string]string{
			"forced.example.com": "trojan_tcp",
		},
	}
	initial := []byte("GET /vless-ws HTTP/1.1\r\nHost: forced.example.com\r\nUpgrade: websocket\r\nConnection: Upgrade\r\n\r\n")

	decision := decideTLSPayloadRoute(cfg, "tls-inner", initial, detect.ClassHTTP, "", "forced.example.com", false)

	if decision.target != cfg.TrojanRawBackendAddr() {
		t.Fatalf("decision.target = %q, want %q", decision.target, cfg.TrojanRawBackendAddr())
	}
	if decision.route != "sni-trojan-tcp" {
		t.Fatalf("decision.route = %q, want sni-trojan-tcp", decision.route)
	}
	if decision.routeSource != "sni" {
		t.Fatalf("decision.routeSource = %q, want sni", decision.routeSource)
	}
	if decision.matchedRoute != "trojan_tcp" {
		t.Fatalf("decision.matchedRoute = %q, want trojan_tcp", decision.matchedRoute)
	}
	if decision.reason != "sni_match" {
		t.Fatalf("decision.reason = %q, want sni_match", decision.reason)
	}
	if decision.host != "forced.example.com" {
		t.Fatalf("decision.host = %q, want forced.example.com", decision.host)
	}
	if decision.path != "/vless-ws" {
		t.Fatalf("decision.path = %q, want /vless-ws", decision.path)
	}
}

func TestDecideTLSPayloadRouteUsesOpenVPNBackendForOpenVPNClass(t *testing.T) {
	cfg := runtime.Config{
		SSHBackend:        "127.0.0.1:22022",
		OpenVPNRawBackend: "127.0.0.1:1194",
	}

	decision := decideTLSPayloadRoute(cfg, "tls-port", nil, detect.ClassOpenVPNRaw, "", "", false)
	if decision.target != cfg.OpenVPNRawBackendAddr() {
		t.Fatalf("decision.target = %q, want %q", decision.target, cfg.OpenVPNRawBackendAddr())
	}
	if decision.route != "openvpn-tcp" {
		t.Fatalf("decision.route = %q, want openvpn-tcp", decision.route)
	}
	if got := backendLabel(cfg, cfg.OpenVPNRawBackendAddr()); got != "openvpn" {
		t.Fatalf("backendLabel(openvpn) = %q, want openvpn", got)
	}
}

func TestHealthBlockReasonUsesBackendStatus(t *testing.T) {
	if got := healthBlockReason(observability.BackendHealthSnapshot{Healthy: false, Status: "down"}, true); got != "backend_down" {
		t.Fatalf("healthBlockReason(down) = %q, want backend_down", got)
	}
	if got := healthBlockReason(observability.BackendHealthSnapshot{Healthy: false, Status: "disabled"}, true); got != "backend_disabled" {
		t.Fatalf("healthBlockReason(disabled) = %q, want backend_disabled", got)
	}
	if got := healthBlockReason(observability.BackendHealthSnapshot{Healthy: false, Status: "degraded"}, true); got != "backend_degraded" {
		t.Fatalf("healthBlockReason(degraded unhealthy) = %q, want backend_degraded", got)
	}
	if got := healthBlockReason(observability.BackendHealthSnapshot{}, false); got != "backend_unhealthy" {
		t.Fatalf("healthBlockReason(unknown) = %q, want backend_unhealthy", got)
	}
}

func TestRouteDecisionEventUsesPassthroughBackendStatus(t *testing.T) {
	cfg := runtime.Config{
		SNIPassthrough: map[string]string{
			"vision.example.com": "127.0.0.1:18443",
		},
	}
	health := &backendHealthState{}
	health.Set(map[string]observability.BackendHealthSnapshot{
		"passthrough:127.0.0.1:18443": {
			Address: "127.0.0.1:18443",
			Healthy: false,
			Status:  "down",
		},
	})

	event := routeDecisionEvent(cfg, health, detect.ClassTLSClientHello, "127.0.0.1:18443", "sni-passthrough", "", "", "", "vision.example.com", "sni_passthrough", 0, "passthrough", "")
	if event.Backend != "passthrough" {
		t.Fatalf("Backend = %q, want passthrough", event.Backend)
	}
	if event.BackendStatus != "down" {
		t.Fatalf("BackendStatus = %q, want down", event.BackendStatus)
	}
}

func TestRouteBlockedByHealthUsesPassthroughBackendKey(t *testing.T) {
	cfg := runtime.Config{
		SNIPassthrough: map[string]string{
			"vision.example.com": "127.0.0.1:18443",
		},
	}
	health := &backendHealthState{}
	health.Set(map[string]observability.BackendHealthSnapshot{
		"passthrough:127.0.0.1:18443": {
			Address: "127.0.0.1:18443",
			Healthy: false,
			Status:  "down",
		},
	})

	if _, blocked := routeBlockedByHealth(health, cfg, "127.0.0.1:18443"); !blocked {
		t.Fatalf("routeBlockedByHealth() = false, want true for down passthrough backend")
	}
}
