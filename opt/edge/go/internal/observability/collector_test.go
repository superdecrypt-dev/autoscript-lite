package observability

import (
	"strings"
	"testing"
	"time"

	"github.com/superdecrypt-dev/autoscript/opt/edge/go/internal/runtime"
)

func TestObserveRouteDecisionCapturesRouteSourceAndMatchedRoute(t *testing.T) {
	collector := NewCollector(time.Unix(1700000000, 0))
	collector.ObserveRouteDecision(RouteDecisionEvent{
		Surface:      "tls-inner",
		DetectClass:  "http",
		RouteSource:  "sni",
		Route:        "sni-vless-tcp",
		MatchedRoute: "vless_tcp",
		Backend:      "vless",
		BackendAddr:  "127.0.0.1:33175",
		Reason:       "sni_match",
		ALPN:         "http/1.1",
		SNI:          "vmess.example.com",
	})

	snapshot := collector.Snapshot(runtime.Config{}, ListenerSnapshot{}, nil, nil)
	if snapshot.LastRoute == nil {
		t.Fatalf("LastRoute = nil, want populated snapshot")
	}
	if snapshot.LastRoute.RouteSource != "sni" {
		t.Fatalf("LastRoute.RouteSource = %q, want sni", snapshot.LastRoute.RouteSource)
	}
	if snapshot.LastRoute.MatchedRoute != "vless_tcp" {
		t.Fatalf("LastRoute.MatchedRoute = %q, want vless_tcp", snapshot.LastRoute.MatchedRoute)
	}

	metrics := string(collector.RenderPrometheus(runtime.Config{}, ListenerSnapshot{}))
	if !strings.Contains(metrics, "edge_mux_route_decisions_total") {
		t.Fatalf("metrics missing edge_mux_route_decisions_total")
	}
	if !strings.Contains(metrics, `source="sni"`) {
		t.Fatalf("metrics missing source label for sni route decision")
	}
	if !strings.Contains(metrics, "edge_mux_sni_route_matches_total") {
		t.Fatalf("metrics missing edge_mux_sni_route_matches_total")
	}
	if !strings.Contains(metrics, `route_alias="vless_tcp"`) {
		t.Fatalf("metrics missing route_alias label for SNI match")
	}
}

func TestObserveHealthRouteBlockAggregatesSurfaceStats(t *testing.T) {
	collector := NewCollector(time.Unix(1700000000, 0))
	collector.ObserveHealthRouteBlock("tls-inner", "sni-vless-tcp", "vless", "down", "close", "backend_down")

	snapshot := collector.Snapshot(runtime.Config{}, ListenerSnapshot{}, nil, nil)
	surface, ok := snapshot.Surface["tls-inner"]
	if !ok {
		t.Fatalf("Surface[tls-inner] missing")
	}
	if surface.HealthBlockedTotal != 1 {
		t.Fatalf("HealthBlockedTotal = %d, want 1", surface.HealthBlockedTotal)
	}
	if surface.HealthBlockReasons["backend_down"] != 1 {
		t.Fatalf("HealthBlockReasons[backend_down] = %d, want 1", surface.HealthBlockReasons["backend_down"])
	}
	if surface.HealthBlockResponse["close"] != 1 {
		t.Fatalf("HealthBlockResponse[close] = %d, want 1", surface.HealthBlockResponse["close"])
	}

	metrics := string(collector.RenderPrometheus(runtime.Config{}, ListenerSnapshot{}))
	if !strings.Contains(metrics, "edge_mux_route_health_blocks_total") {
		t.Fatalf("metrics missing edge_mux_route_health_blocks_total")
	}
	if !strings.Contains(metrics, `reason="backend_down"`) {
		t.Fatalf("metrics missing backend_down reason label")
	}
}

func TestSnapshotIncludesSNIPassthroughMap(t *testing.T) {
	collector := NewCollector(time.Unix(1700000000, 0))
	cfg := runtime.Config{
		SNIPassthrough: map[string]string{
			"vision.example.com": "127.0.0.1:8443",
		},
	}

	snapshot := collector.Snapshot(cfg, ListenerSnapshot{}, nil, nil)
	if got := snapshot.SNIPassthrough["vision.example.com"]; got != "127.0.0.1:8443" {
		t.Fatalf("Snapshot().SNIPassthrough = %q, want 127.0.0.1:8443", got)
	}
}

func TestObservePassthroughMetricsAggregatesSurfaceStats(t *testing.T) {
	collector := NewCollector(time.Unix(1700000000, 0))
	collector.ObserveRouteDecision(RouteDecisionEvent{
		Surface:     "tls-port",
		DetectClass: "tls_client_hello",
		RouteSource: "passthrough",
		Route:       "sni-passthrough",
		Backend:     "passthrough",
		BackendAddr: "127.0.0.1:18443",
		Reason:      "sni_passthrough",
		SNI:         "vision.example.com",
	})
	collector.ObserveHealthRouteBlock("tls-port", "sni-passthrough", "passthrough", "down", "close", "backend_down")
	collector.ObserveBackendDialFailure("passthrough", "tls-port:sni-passthrough")

	snapshot := collector.Snapshot(runtime.Config{}, ListenerSnapshot{}, nil, nil)
	surface, ok := snapshot.Surface["tls-port"]
	if !ok {
		t.Fatalf("Surface[tls-port] missing")
	}
	if surface.PassthroughRouteHits != 1 {
		t.Fatalf("PassthroughRouteHits = %d, want 1", surface.PassthroughRouteHits)
	}
	if surface.PassthroughBlocks != 1 {
		t.Fatalf("PassthroughBlocks = %d, want 1", surface.PassthroughBlocks)
	}
	if surface.PassthroughDialFails != 1 {
		t.Fatalf("PassthroughDialFails = %d, want 1", surface.PassthroughDialFails)
	}

	metrics := string(collector.RenderPrometheus(runtime.Config{}, ListenerSnapshot{}))
	if !strings.Contains(metrics, "edge_mux_passthrough_route_hits_total") {
		t.Fatalf("metrics missing edge_mux_passthrough_route_hits_total")
	}
	if !strings.Contains(metrics, `target="127.0.0.1:18443"`) {
		t.Fatalf("metrics missing passthrough target label")
	}
	if !strings.Contains(metrics, "edge_mux_passthrough_health_blocks_total") {
		t.Fatalf("metrics missing edge_mux_passthrough_health_blocks_total")
	}
	if !strings.Contains(metrics, "edge_mux_passthrough_backend_dial_failures_total") {
		t.Fatalf("metrics missing edge_mux_passthrough_backend_dial_failures_total")
	}
}

func TestSnapshotIncludesConfiguredRouteTable(t *testing.T) {
	collector := NewCollector(time.Unix(1700000000, 0))
	cfg := runtime.Config{
		HTTPBackend:       "127.0.0.1:18080",
		XrayDirectBackend: "127.0.0.1:22022",
		XrayTLSBackend:    "127.0.0.1:22443",
		XrayWSBackend:     "127.0.0.1:10015",
		VLESSRawBackend:   "127.0.0.1:33175",
		TrojanRawBackend:  "127.0.0.1:48778",
		SNIRoutes: map[string]string{
			"alpha.example.com": "vless_tcp",
			"beta.example.com":  "ssh_ws",
		},
		SNIPassthrough: map[string]string{
			"gamma.example.com": "127.0.0.1:18443",
		},
	}

	snapshot := collector.Snapshot(cfg, ListenerSnapshot{}, nil, nil)
	if len(snapshot.ConfiguredRoutes) != 3 {
		t.Fatalf("len(ConfiguredRoutes) = %d, want 3", len(snapshot.ConfiguredRoutes))
	}
	if snapshot.ConfiguredRoutes[0].Host != "alpha.example.com" {
		t.Fatalf("ConfiguredRoutes[0].Host = %q, want alpha.example.com", snapshot.ConfiguredRoutes[0].Host)
	}
	if snapshot.ConfiguredRoutes[0].Backend != "vless" || snapshot.ConfiguredRoutes[0].BackendAddr != "127.0.0.1:33175" {
		t.Fatalf("ConfiguredRoutes[0] = %#v, want vless -> 127.0.0.1:33175", snapshot.ConfiguredRoutes[0])
	}
	if snapshot.ConfiguredRoutes[1].Host != "beta.example.com" || snapshot.ConfiguredRoutes[1].RouteAlias != "ssh_ws" {
		t.Fatalf("ConfiguredRoutes[1] = %#v, want beta.example.com ssh_ws", snapshot.ConfiguredRoutes[1])
	}
	if snapshot.ConfiguredRoutes[2].Host != "gamma.example.com" || snapshot.ConfiguredRoutes[2].Mode != "passthrough" {
		t.Fatalf("ConfiguredRoutes[2] = %#v, want gamma.example.com passthrough", snapshot.ConfiguredRoutes[2])
	}
	if snapshot.ConfiguredRoutes[2].HealthKey != "passthrough:127.0.0.1:18443" {
		t.Fatalf("ConfiguredRoutes[2].HealthKey = %q, want passthrough:127.0.0.1:18443", snapshot.ConfiguredRoutes[2].HealthKey)
	}
}
