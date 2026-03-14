package main

import (
	"testing"

	"github.com/superdecrypt-dev/autoscript/opt/edge/go/internal/detect"
	"github.com/superdecrypt-dev/autoscript/opt/edge/go/internal/observability"
	"github.com/superdecrypt-dev/autoscript/opt/edge/go/internal/runtime"
)

func TestDecideHTTPRouteUnauthorizedForUnknownWebSocket(t *testing.T) {
	cfg := runtime.Config{HTTPBackend: "127.0.0.1:18080"}
	initial := []byte("GET / HTTP/1.1\r\nHost: example.com\r\nUpgrade: websocket\r\nConnection: Upgrade\r\n\r\n")

	decision := decideHTTPRoute(cfg, "tls-inner", initial, "", "")

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

	decision := decideHTTPRoute(cfg, "tls-inner", initial, "", "")

	if decision.Route != "ssh-ws-like" {
		t.Fatalf("route = %q, want ssh-ws-like", decision.Route)
	}
	if decision.Status != 0 {
		t.Fatalf("status = %d, want 0", decision.Status)
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

	decision := decideTLSPayloadRoute(cfg, "tls-inner", initial, detect.ClassHTTP, "http/1.1", "vmess.example.com")

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

	decision := decideTLSPayloadRoute(cfg, "tls-inner", initial, detect.ClassHTTP, "http/1.1", "unknown.example.com")

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

	decision := decideTLSPayloadRoute(cfg, "tls-inner", initial, detect.ClassHTTP, "", "forced.example.com")

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
