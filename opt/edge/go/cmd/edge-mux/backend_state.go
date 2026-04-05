package main

import (
	"context"
	"log"
	"net"
	"strings"
	"sync"
	"time"

	"github.com/superdecrypt-dev/autoscript/opt/edge/go/internal/observability"
	"github.com/superdecrypt-dev/autoscript/opt/edge/go/internal/runtime"
)

const backendRefreshInterval = 5 * time.Second

type backendHealthState struct {
	mu        sync.RWMutex
	snapshots map[string]observability.BackendHealthSnapshot
}

func newBackendHealthState(cfg runtime.Config) *backendHealthState {
	state := &backendHealthState{}
	state.Refresh(cfg)
	return state
}

func (s *backendHealthState) Refresh(cfg runtime.Config) {
	if s == nil {
		return
	}
	s.Set(backendHealthSnapshot(cfg))
}

func (s *backendHealthState) Set(snapshots map[string]observability.BackendHealthSnapshot) {
	if s == nil {
		return
	}
	clone := make(map[string]observability.BackendHealthSnapshot, len(snapshots))
	for key, value := range snapshots {
		clone[key] = value
	}
	s.mu.Lock()
	s.snapshots = clone
	s.mu.Unlock()
}

func (s *backendHealthState) Snapshot() map[string]observability.BackendHealthSnapshot {
	if s == nil {
		return nil
	}
	s.mu.RLock()
	defer s.mu.RUnlock()
	clone := make(map[string]observability.BackendHealthSnapshot, len(s.snapshots))
	for key, value := range s.snapshots {
		clone[key] = value
	}
	return clone
}

func (s *backendHealthState) Lookup(name string) (observability.BackendHealthSnapshot, bool) {
	if s == nil || strings.TrimSpace(name) == "" {
		return observability.BackendHealthSnapshot{}, false
	}
	s.mu.RLock()
	defer s.mu.RUnlock()
	snapshot, ok := s.snapshots[name]
	return snapshot, ok
}

func (s *backendHealthState) MarkDialFailure(name, addr string, err error) {
	if s == nil || strings.TrimSpace(name) == "" {
		return
	}
	now := time.Now().Unix()
	reason := "dial failed"
	if err != nil {
		reason = err.Error()
	}
	s.mu.Lock()
	defer s.mu.Unlock()
	s.snapshots[name] = observability.BackendHealthSnapshot{
		Address:       addr,
		Healthy:       false,
		Status:        "down",
		Reason:        reason,
		CheckedAtUnix: now,
	}
}

func (s *backendHealthState) MarkDialSuccess(name, addr string, latency time.Duration) {
	if s == nil || strings.TrimSpace(name) == "" {
		return
	}
	status := "up"
	latencyMS := latency.Milliseconds()
	if latencyMS >= 250 {
		status = "degraded"
	}
	s.mu.Lock()
	defer s.mu.Unlock()
	s.snapshots[name] = observability.BackendHealthSnapshot{
		Address:       addr,
		Healthy:       true,
		Status:        status,
		LatencyMS:     latencyMS,
		CheckedAtUnix: time.Now().Unix(),
	}
}

func monitorBackendState(ctx context.Context, logger *log.Logger, live *runtime.Live, health *backendHealthState) error {
	if live == nil || health == nil {
		return nil
	}
	ticker := time.NewTicker(backendRefreshInterval)
	defer ticker.Stop()

	var lastDiscoveryErr string
	for {
		select {
		case <-ctx.Done():
			return nil
		case <-ticker.C:
		}

		cfg := live.Config()
		refreshed, changed, err := runtime.RefreshDiscoveredRawBackends(cfg)
		if err != nil {
			if logger != nil {
				errText := err.Error()
				if errText != lastDiscoveryErr {
					logger.Printf("edge-mux backend discovery failed file=%s: %v", cfg.XrayInboundsFile, err)
					lastDiscoveryErr = errText
				}
			}
			health.Refresh(cfg)
			continue
		}
		if lastDiscoveryErr != "" && logger != nil {
			logger.Printf("edge-mux backend discovery recovered file=%s", refreshed.XrayInboundsFile)
			lastDiscoveryErr = ""
		}
		if changed {
			live.Set(refreshed)
			if logger != nil {
				logger.Printf(
					"edge-mux backend discovery updated xray_fallback_backend=%s vless_raw_backend=%s source=%s trojan_raw_backend=%s source=%s",
					refreshed.XrayFallbackBackendAddr(),
					refreshed.VLESSRawBackendAddr(),
					refreshed.VLESSRawSource,
					refreshed.TrojanRawBackendAddr(),
					refreshed.TrojanRawSource,
				)
			}
		}
		health.Refresh(refreshed)
	}
}

func backendHealthKey(cfg runtime.Config, target string) string {
	switch target {
	case cfg.HTTPBackendAddr():
		return "http"
	case cfg.XrayDirectBackendAddr():
		return "xray-direct"
	case cfg.XrayTLSBackendAddr():
		return "xray-tls"
	case cfg.XrayWSBackendAddr():
		return "xray-ws"
	case cfg.XrayFallbackBackendAddr():
		return "fallback"
	case cfg.VLESSRawBackendAddr():
		return "vless"
	case cfg.TrojanRawBackendAddr():
		return "trojan"
	default:
		if cfg.IsPassthroughBackend(target) {
			return passthroughBackendHealthKey(target)
		}
		return ""
	}
}

func passthroughBackendHealthKey(target string) string {
	target = strings.TrimSpace(target)
	if target == "" {
		return ""
	}
	return "passthrough:" + target
}

func backendStatus(snapshot observability.BackendHealthSnapshot, ok bool) string {
	if !ok {
		return "unknown"
	}
	status := strings.TrimSpace(snapshot.Status)
	if status != "" {
		return status
	}
	if snapshot.Healthy {
		return "up"
	}
	return "down"
}

func routeBlockedByHealth(health *backendHealthState, cfg runtime.Config, target string) (observability.BackendHealthSnapshot, bool) {
	key := backendHealthKey(cfg, target)
	if key == "" {
		return observability.BackendHealthSnapshot{}, false
	}
	snapshot, ok := health.Lookup(key)
	if !ok || snapshot.Healthy {
		return snapshot, false
	}
	return snapshot, true
}

func healthBlockReason(snapshot observability.BackendHealthSnapshot, ok bool) string {
	status := backendStatus(snapshot, ok)
	switch status {
	case "down":
		return "backend_down"
	case "disabled":
		return "backend_disabled"
	case "degraded":
		if !snapshot.Healthy {
			return "backend_degraded"
		}
	}
	return "backend_unhealthy"
}

func healthBlockResponse(sendHTTP502 bool) string {
	if sendHTTP502 {
		return "http_502"
	}
	return "close"
}

func emitBlockedRoute(logger *log.Logger, collector *observability.Collector, conn net.Conn, event observability.RouteDecisionEvent, snapshot observability.BackendHealthSnapshot, sendHTTP502 bool) {
	event.BackendStatus = backendStatus(snapshot, true)
	event.Reason = healthBlockReason(snapshot, true)
	if sendHTTP502 {
		event.HTTPStatus = 502
	}
	if collector != nil {
		collector.ObserveHealthRouteBlock(event.Surface, event.Route, event.Backend, event.BackendStatus, healthBlockResponse(sendHTTP502), event.Reason)
	}
	emitRouteDecision(logger, collector, conn, event)
	if sendHTTP502 {
		_ = writeHTTPError(conn, 502, "Bad Gateway")
	}
}

func logRouteDecision(logger *log.Logger, conn net.Conn, event observability.RouteDecisionEvent) {
	if logger == nil {
		return
	}
	logger.Printf(
		"edge-mux route surface=%s class=%s route_source=%s matched_route=%s route=%s backend=%s backend_addr=%s backend_status=%s http_status=%d reason=%s host=%q path=%q alpn=%s sni=%q remote=%s",
		logValue(event.Surface, 64),
		logValue(event.DetectClass, 32),
		logValue(event.RouteSource, 16),
		logValue(event.MatchedRoute, 64),
		logValue(event.Route, 64),
		logValue(event.Backend, 32),
		logValue(event.BackendAddr, 128),
		logValue(event.BackendStatus, 32),
		event.HTTPStatus,
		logValue(event.Reason, 128),
		logValue(event.Host, 255),
		logValue(event.Path, 255),
		logValue(event.ALPN, 32),
		logValue(event.SNI, 255),
		logValue(safeRemote(conn), 128),
	)
}

func logValue(value string, max int) string {
	text := strings.TrimSpace(value)
	if text == "" {
		return "-"
	}
	if max > 0 && len(text) > max {
		return text[:max]
	}
	return text
}
