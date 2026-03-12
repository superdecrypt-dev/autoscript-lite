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

	event := routeDecisionEvent(cfg, health, detect.ClassVLESSRaw, cfg.VLESSRawBackendAddr(), "vless-tcp", "", "", "", "", "", 0)
	if event.Backend != "vless" {
		t.Fatalf("Backend = %q, want vless", event.Backend)
	}
	if event.BackendStatus != "down" {
		t.Fatalf("BackendStatus = %q, want down", event.BackendStatus)
	}
}
