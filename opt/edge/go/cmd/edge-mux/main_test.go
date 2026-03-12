package main

import (
	"testing"

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
