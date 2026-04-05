package observability

import (
	"bytes"
	"fmt"
	"sort"
	"strings"
	"sync"
	"time"

	"github.com/superdecrypt-dev/autoscript/opt/edge/go/internal/detect"
	"github.com/superdecrypt-dev/autoscript/opt/edge/go/internal/runtime"
)

type sampleKey struct {
	name   string
	labels string
}

type ListenerSnapshot struct {
	HTTPAddr             string
	TLSAddr              string
	MetricsAddr          string
	HTTPUp               bool
	TLSUp                bool
	MetricsUp            bool
	TLSCertSubject       string
	TLSCertNotBefore     string
	TLSCertNotAfter      string
	TLSAdvertisedALPN    []string
	TLSMinVersion        string
	TLSCertExpiresUnix   int64
	TLSCertValidFromUnix int64
}

type LastRouteSnapshot struct {
	SeenAtUnix    int64  `json:"seen_at_unix"`
	Surface       string `json:"surface"`
	DetectClass   string `json:"detect_class,omitempty"`
	RouteSource   string `json:"route_source,omitempty"`
	Route         string `json:"route"`
	MatchedRoute  string `json:"matched_route,omitempty"`
	Backend       string `json:"backend"`
	BackendAddr   string `json:"backend_addr,omitempty"`
	BackendStatus string `json:"backend_status,omitempty"`
	Reason        string `json:"reason,omitempty"`
	HTTPStatus    int    `json:"http_status,omitempty"`
	Host          string `json:"host,omitempty"`
	Path          string `json:"path,omitempty"`
	ALPN          string `json:"alpn,omitempty"`
	SNI           string `json:"sni,omitempty"`
}

type RouteDecisionEvent struct {
	Surface       string
	DetectClass   string
	RouteSource   string
	Route         string
	MatchedRoute  string
	Backend       string
	BackendAddr   string
	BackendStatus string
	Reason        string
	HTTPStatus    int
	Host          string
	Path          string
	ALPN          string
	SNI           string
}

type SurfaceSnapshot struct {
	ActiveConnections    int64             `json:"active_connections"`
	AcceptedTotal        uint64            `json:"accepted_total"`
	RejectedTotal        uint64            `json:"rejected_total"`
	HealthBlockedTotal   uint64            `json:"health_blocked_total"`
	PassthroughRouteHits uint64            `json:"passthrough_route_hits_total"`
	PassthroughBlocks    uint64            `json:"passthrough_health_blocks_total"`
	PassthroughDialFails uint64            `json:"passthrough_backend_dial_failures_total"`
	ReadInitialErrors    uint64            `json:"read_initial_errors_total"`
	IngressWrapErrors    uint64            `json:"ingress_wrap_errors_total"`
	TLSHandshakeFailures uint64            `json:"tls_handshake_failures_total"`
	DetectTotals         map[string]uint64 `json:"detect_totals,omitempty"`
	RouteTotals          map[string]uint64 `json:"route_totals,omitempty"`
	HealthBlockReasons   map[string]uint64 `json:"health_block_reasons,omitempty"`
	HealthBlockResponse  map[string]uint64 `json:"health_block_response,omitempty"`
}

type BackendHealthSnapshot struct {
	Address       string `json:"address"`
	Healthy       bool   `json:"healthy"`
	Status        string `json:"status,omitempty"`
	Reason        string `json:"reason,omitempty"`
	LatencyMS     int64  `json:"latency_ms,omitempty"`
	CheckedAtUnix int64  `json:"checked_at_unix,omitempty"`
}

type ConfiguredRouteSnapshot struct {
	Host        string `json:"host"`
	Mode        string `json:"mode"`
	RouteAlias  string `json:"route_alias,omitempty"`
	Route       string `json:"route"`
	Backend     string `json:"backend"`
	BackendAddr string `json:"backend_addr"`
	HealthKey   string `json:"health_key,omitempty"`
}

type AbuseSnapshot struct {
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

type StatusSnapshot struct {
	OK                        bool                             `json:"ok"`
	Provider                  string                           `json:"provider"`
	StartedAt                 string                           `json:"started_at"`
	UptimeSeconds             int64                            `json:"uptime_seconds"`
	PublicHTTPListen          string                           `json:"public_http_listen"`
	PublicTLSListen           string                           `json:"public_tls_listen"`
	MetricsListen             string                           `json:"metrics_listen"`
	HTTPBackend               string                           `json:"http_backend"`
	VLESSRawBackend           string                           `json:"vless_raw_backend"`
	VLESSRawBackendSource     string                           `json:"vless_raw_backend_source,omitempty"`
	TrojanRawBackend          string                           `json:"trojan_raw_backend"`
	TrojanRawBackendSource    string                           `json:"trojan_raw_backend_source,omitempty"`
	MetricsEnabled            bool                             `json:"metrics_enabled"`
	ClassicTLSOn80            bool                             `json:"classic_tls_on_80"`
	AcceptProxyProtocol       bool                             `json:"accept_proxy_protocol"`
	TrustedProxyCIDRs         []string                         `json:"trusted_proxy_cidrs"`
	SNIRoutes                 map[string]string                `json:"sni_routes,omitempty"`
	SNIPassthrough            map[string]string                `json:"sni_passthrough,omitempty"`
	ConfiguredRoutes          []ConfiguredRouteSnapshot        `json:"configured_routes,omitempty"`
	DetectTimeoutMilliseconds int64                            `json:"detect_timeout_milliseconds"`
	TLSHandshakeTimeoutMS     int64                            `json:"tls_handshake_timeout_milliseconds"`
	MaxConnections            int                              `json:"max_connections"`
	MaxConnectionsPerIP       int                              `json:"max_connections_per_ip"`
	AcceptRatePerIP           int                              `json:"accept_rate_limit_per_ip"`
	AcceptRateWindowSeconds   int64                            `json:"accept_rate_window_seconds"`
	ReloadSuccess             uint64                           `json:"reload_success"`
	LastReloadUnix            int64                            `json:"last_reload_unix"`
	ActiveConnectionsTotal    int64                            `json:"active_connections_total"`
	ActiveConnectionsSurface  map[string]int64                 `json:"active_connections_by_surface"`
	Surface                   map[string]SurfaceSnapshot       `json:"surface,omitempty"`
	BackendHealth             map[string]BackendHealthSnapshot `json:"backend_health,omitempty"`
	Abuse                     *AbuseSnapshot                   `json:"abuse,omitempty"`
	ListenerUp                map[string]bool                  `json:"listener_up"`
	TLSCertificateSubject     string                           `json:"tls_certificate_subject"`
	TLSCertificateNotBefore   string                           `json:"tls_certificate_not_before"`
	TLSCertificateNotAfter    string                           `json:"tls_certificate_not_after"`
	TLSAdvertisedALPN         []string                         `json:"tls_advertised_alpn"`
	TLSMinVersion             string                           `json:"tls_min_version"`
	LastRoute                 *LastRouteSnapshot               `json:"last_route,omitempty"`
}

type Collector struct {
	startedAt time.Time

	mu              sync.Mutex
	counters        map[sampleKey]uint64
	activeTotal     int64
	activeBySurface map[string]int64
	reloadSuccess   uint64
	lastReloadUnix  int64
	lastRoute       *LastRouteSnapshot
}

func NewCollector(startedAt time.Time) *Collector {
	if startedAt.IsZero() {
		startedAt = time.Now()
	}
	return &Collector{
		startedAt:       startedAt.UTC(),
		counters:        make(map[sampleKey]uint64),
		activeBySurface: make(map[string]int64),
	}
}

func (c *Collector) TrackConnection(surface string) func() {
	c.mu.Lock()
	c.counters[sampleKey{name: "edge_mux_connections_accepted_total", labels: labels("surface", surface)}]++
	c.activeTotal++
	c.activeBySurface[surface]++
	c.mu.Unlock()

	var once sync.Once
	return func() {
		once.Do(func() {
			c.mu.Lock()
			defer c.mu.Unlock()
			if c.activeTotal > 0 {
				c.activeTotal--
			}
			current := c.activeBySurface[surface]
			switch {
			case current <= 1:
				delete(c.activeBySurface, surface)
			default:
				c.activeBySurface[surface] = current - 1
			}
		})
	}
}

func (c *Collector) ObserveReject(surface, reason string) {
	c.incCounter("edge_mux_connections_rejected_total", labels("surface", surface, "reason", reason))
}

func (c *Collector) ObserveIngressWrapError(surface string) {
	c.incCounter("edge_mux_ingress_wrap_errors_total", labels("surface", surface))
}

func (c *Collector) ObserveReadInitialError(surface string) {
	c.incCounter("edge_mux_read_initial_errors_total", labels("surface", surface))
}

func (c *Collector) ObserveDetect(surface string, class detect.InitialClass) {
	c.incCounter("edge_mux_detect_classifications_total", labels("surface", surface, "class", detectClassName(class)))
}

func (c *Collector) ObserveTLSHandshakeFailure(surface string) {
	c.incCounter("edge_mux_tls_handshake_failures_total", labels("surface", surface))
}

func (c *Collector) ObserveBackendDialFailure(backend, context string) {
	c.incCounter("edge_mux_backend_dial_failures_total", labels("backend", backend, "context", context))
	if strings.TrimSpace(backend) == "passthrough" {
		c.incCounter("edge_mux_passthrough_backend_dial_failures_total", labels(
			"surface", passthroughSurfaceFromContext(context),
			"context", fallback(context, "unknown"),
		))
	}
}

func (c *Collector) ObserveHealthRouteBlock(surface, route, backend, backendStatus, response, reason string) {
	c.incCounter("edge_mux_route_health_blocks_total", labels(
		"surface", fallback(surface, "unknown"),
		"route", fallback(route, "unknown"),
		"backend", fallback(backend, "unknown"),
		"backend_status", fallback(backendStatus, "unknown"),
		"response", fallback(response, "close"),
		"reason", fallback(reason, "backend_unhealthy"),
	))
	if strings.TrimSpace(backend) == "passthrough" {
		c.incCounter("edge_mux_passthrough_health_blocks_total", labels(
			"surface", fallback(surface, "unknown"),
			"backend_status", fallback(backendStatus, "unknown"),
			"response", fallback(response, "close"),
			"reason", fallback(reason, "backend_unhealthy"),
		))
	}
}

func (c *Collector) ObserveBridgeBytes(context string, leftToRight, rightToLeft uint64) {
	if leftToRight > 0 {
		c.addCounter("edge_mux_bridge_bytes_total", labels("context", context, "direction", "client_to_backend"), leftToRight)
	}
	if rightToLeft > 0 {
		c.addCounter("edge_mux_bridge_bytes_total", labels("context", context, "direction", "backend_to_client"), rightToLeft)
	}
}

func (c *Collector) ObserveBridgeError(context string) {
	c.incCounter("edge_mux_bridge_errors_total", labels("context", context))
}

func (c *Collector) ObserveRouteDecision(event RouteDecisionEvent) {
	surface := fallback(event.Surface, "unknown")
	route := fallback(event.Route, "unknown")
	backend := fallback(event.Backend, "unknown")
	alpn := fallback(event.ALPN, "none")
	routeSource := fallback(event.RouteSource, "detect")
	matchedRoute := strings.TrimSpace(event.MatchedRoute)
	c.incCounter("edge_mux_route_decisions_total", labels("surface", surface, "route", route, "backend", backend, "alpn", alpn, "source", routeSource))
	if routeSource == "sni" && matchedRoute != "" {
		c.incCounter("edge_mux_sni_route_matches_total", labels("surface", surface, "route_alias", matchedRoute, "backend", backend))
	}
	if routeSource == "passthrough" || backend == "passthrough" {
		c.incCounter("edge_mux_passthrough_route_hits_total", labels(
			"surface", surface,
			"target", fallback(event.BackendAddr, "unknown"),
		))
	}
	c.mu.Lock()
	defer c.mu.Unlock()
	c.lastRoute = &LastRouteSnapshot{
		SeenAtUnix:    time.Now().Unix(),
		Surface:       truncate(surface, 64),
		DetectClass:   truncate(event.DetectClass, 32),
		RouteSource:   truncate(routeSource, 16),
		Route:         truncate(route, 64),
		MatchedRoute:  truncate(matchedRoute, 64),
		Backend:       truncate(backend, 32),
		BackendAddr:   truncate(event.BackendAddr, 128),
		BackendStatus: truncate(event.BackendStatus, 32),
		Reason:        truncate(event.Reason, 128),
		HTTPStatus:    event.HTTPStatus,
		Host:          truncate(event.Host, 255),
		Path:          truncate(event.Path, 255),
		ALPN:          truncate(alpn, 32),
		SNI:           truncate(event.SNI, 255),
	}
}

func (c *Collector) ObserveReloadFailure(stage string) {
	c.incCounter("edge_mux_reload_total", labels("result", "failure", "stage", stage))
}

func (c *Collector) ObserveReloadSuccess() {
	now := time.Now().Unix()
	c.mu.Lock()
	defer c.mu.Unlock()
	c.counters[sampleKey{name: "edge_mux_reload_total", labels: labels("result", "success", "stage", "apply")}]++
	c.reloadSuccess++
	c.lastReloadUnix = now
}

func (c *Collector) Snapshot(cfg runtime.Config, listeners ListenerSnapshot, backendHealth map[string]BackendHealthSnapshot, abuse *AbuseSnapshot) StatusSnapshot {
	c.mu.Lock()
	activeBySurface := make(map[string]int64, len(c.activeBySurface))
	for key, value := range c.activeBySurface {
		activeBySurface[key] = value
	}
	reloadSuccess := c.reloadSuccess
	lastReloadUnix := c.lastReloadUnix
	activeTotal := c.activeTotal
	startedAt := c.startedAt
	counterKeys := make([]sampleKey, 0, len(c.counters))
	for key := range c.counters {
		counterKeys = append(counterKeys, key)
	}
	counterValues := make([]uint64, len(counterKeys))
	for i, key := range counterKeys {
		counterValues[i] = c.counters[key]
	}
	var lastRoute *LastRouteSnapshot
	if c.lastRoute != nil {
		clone := *c.lastRoute
		lastRoute = &clone
	}
	c.mu.Unlock()

	surfaceStats := make(map[string]SurfaceSnapshot)
	for surface, active := range activeBySurface {
		stats := surfaceStats[surface]
		stats.ActiveConnections = active
		surfaceStats[surface] = stats
	}
	for i, key := range counterKeys {
		lbl := parseLabelSet(key.labels)
		surface := strings.TrimSpace(lbl["surface"])
		if surface == "" {
			continue
		}
		stats := surfaceStats[surface]
		value := counterValues[i]
		switch key.name {
		case "edge_mux_connections_accepted_total":
			stats.AcceptedTotal += value
		case "edge_mux_connections_rejected_total":
			stats.RejectedTotal += value
		case "edge_mux_read_initial_errors_total":
			stats.ReadInitialErrors += value
		case "edge_mux_ingress_wrap_errors_total":
			stats.IngressWrapErrors += value
		case "edge_mux_tls_handshake_failures_total":
			stats.TLSHandshakeFailures += value
		case "edge_mux_detect_classifications_total":
			if stats.DetectTotals == nil {
				stats.DetectTotals = make(map[string]uint64)
			}
			stats.DetectTotals[fallback(lbl["class"], "unknown")] += value
		case "edge_mux_route_decisions_total":
			if stats.RouteTotals == nil {
				stats.RouteTotals = make(map[string]uint64)
			}
			stats.RouteTotals[fallback(lbl["route"], "unknown")] += value
		case "edge_mux_passthrough_route_hits_total":
			stats.PassthroughRouteHits += value
		case "edge_mux_route_health_blocks_total":
			stats.HealthBlockedTotal += value
			if stats.HealthBlockReasons == nil {
				stats.HealthBlockReasons = make(map[string]uint64)
			}
			stats.HealthBlockReasons[fallback(lbl["reason"], "backend_unhealthy")] += value
			if stats.HealthBlockResponse == nil {
				stats.HealthBlockResponse = make(map[string]uint64)
			}
			stats.HealthBlockResponse[fallback(lbl["response"], "close")] += value
		case "edge_mux_passthrough_health_blocks_total":
			stats.PassthroughBlocks += value
		case "edge_mux_passthrough_backend_dial_failures_total":
			stats.PassthroughDialFails += value
		}
		surfaceStats[surface] = stats
	}

	var backendCopy map[string]BackendHealthSnapshot
	if len(backendHealth) > 0 {
		backendCopy = make(map[string]BackendHealthSnapshot, len(backendHealth))
		for key, value := range backendHealth {
			backendCopy[key] = value
		}
	}
	allBackendHealthy := true
	if len(backendCopy) > 0 {
		for _, snapshot := range backendCopy {
			if !snapshot.Healthy {
				allBackendHealthy = false
				break
			}
		}
	}
	var abuseCopy *AbuseSnapshot
	if abuse != nil {
		clone := *abuse
		if len(abuse.BlockedUntilUnix) > 0 {
			clone.BlockedUntilUnix = make(map[string]int64, len(abuse.BlockedUntilUnix))
			for key, value := range abuse.BlockedUntilUnix {
				clone.BlockedUntilUnix[key] = value
			}
		}
		if len(abuse.BlockedReason) > 0 {
			clone.BlockedReason = make(map[string]string, len(abuse.BlockedReason))
			for key, value := range abuse.BlockedReason {
				clone.BlockedReason[key] = value
			}
		}
		if len(abuse.BlockedSurface) > 0 {
			clone.BlockedSurface = make(map[string]string, len(abuse.BlockedSurface))
			for key, value := range abuse.BlockedSurface {
				clone.BlockedSurface[key] = value
			}
		}
		if len(abuse.RejectReasons) > 0 {
			clone.RejectReasons = make(map[string]uint64, len(abuse.RejectReasons))
			for key, value := range abuse.RejectReasons {
				clone.RejectReasons[key] = value
			}
		}
		if len(abuse.RejectSurfaces) > 0 {
			clone.RejectSurfaces = make(map[string]uint64, len(abuse.RejectSurfaces))
			for key, value := range abuse.RejectSurfaces {
				clone.RejectSurfaces[key] = value
			}
		}
		abuseCopy = &clone
	}

	return StatusSnapshot{
		OK:                        listeners.HTTPUp && listeners.TLSUp && allBackendHealthy,
		Provider:                  cfg.Provider,
		StartedAt:                 startedAt.Format(time.RFC3339),
		UptimeSeconds:             int64(time.Since(startedAt).Seconds()),
		PublicHTTPListen:          listeners.HTTPAddr,
		PublicTLSListen:           listeners.TLSAddr,
		MetricsListen:             listeners.MetricsAddr,
		HTTPBackend:               cfg.HTTPBackendAddr(),
		VLESSRawBackend:           cfg.VLESSRawBackendAddr(),
		VLESSRawBackendSource:     cfg.VLESSRawSource,
		TrojanRawBackend:          cfg.TrojanRawBackendAddr(),
		TrojanRawBackendSource:    cfg.TrojanRawSource,
		MetricsEnabled:            cfg.MetricsEnabled,
		ClassicTLSOn80:            cfg.ClassicTLSOn80,
		AcceptProxyProtocol:       cfg.AcceptProxyProtocol,
		TrustedProxyCIDRs:         append([]string(nil), cfg.TrustedProxyCIDRs...),
		SNIRoutes:                 cloneStringMap(cfg.SNIRoutes),
		SNIPassthrough:            cloneStringMap(cfg.SNIPassthrough),
		ConfiguredRoutes:          configuredRouteTable(cfg),
		DetectTimeoutMilliseconds: int64(cfg.DetectTimeout / time.Millisecond),
		TLSHandshakeTimeoutMS:     int64(cfg.TLSHandshakeTimeout / time.Millisecond),
		MaxConnections:            cfg.MaxConnections,
		MaxConnectionsPerIP:       cfg.MaxConnectionsPerIP,
		AcceptRatePerIP:           cfg.AcceptRatePerIP,
		AcceptRateWindowSeconds:   int64(cfg.AcceptRateWindow / time.Second),
		ReloadSuccess:             reloadSuccess,
		LastReloadUnix:            lastReloadUnix,
		ActiveConnectionsTotal:    activeTotal,
		ActiveConnectionsSurface:  activeBySurface,
		Surface:                   surfaceStats,
		BackendHealth:             backendCopy,
		Abuse:                     abuseCopy,
		ListenerUp: map[string]bool{
			"http":    listeners.HTTPUp,
			"tls":     listeners.TLSUp,
			"metrics": listeners.MetricsUp,
		},
		TLSCertificateSubject:   listeners.TLSCertSubject,
		TLSCertificateNotBefore: listeners.TLSCertNotBefore,
		TLSCertificateNotAfter:  listeners.TLSCertNotAfter,
		TLSAdvertisedALPN:       append([]string(nil), listeners.TLSAdvertisedALPN...),
		TLSMinVersion:           listeners.TLSMinVersion,
		LastRoute:               lastRoute,
	}
}

func cloneStringMap(in map[string]string) map[string]string {
	if len(in) == 0 {
		return nil
	}
	out := make(map[string]string, len(in))
	for key, value := range in {
		out[key] = value
	}
	return out
}

func configuredRouteTable(cfg runtime.Config) []ConfiguredRouteSnapshot {
	total := len(cfg.SNIRoutes) + len(cfg.SNIPassthrough)
	if total == 0 {
		return nil
	}
	entries := make([]ConfiguredRouteSnapshot, 0, total)
	for host, alias := range cfg.SNIRoutes {
		backend, addr, healthKey, ok := configuredSNIRouteTarget(cfg, alias)
		if !ok {
			continue
		}
		entries = append(entries, ConfiguredRouteSnapshot{
			Host:        host,
			Mode:        "route",
			RouteAlias:  alias,
			Route:       "sni-" + strings.ReplaceAll(alias, "_", "-"),
			Backend:     backend,
			BackendAddr: addr,
			HealthKey:   healthKey,
		})
	}
	for host, target := range cfg.SNIPassthrough {
		target = strings.TrimSpace(target)
		if target == "" {
			continue
		}
		entries = append(entries, ConfiguredRouteSnapshot{
			Host:        host,
			Mode:        "passthrough",
			Route:       "sni-passthrough",
			Backend:     "passthrough",
			BackendAddr: target,
			HealthKey:   "passthrough:" + target,
		})
	}
	sort.Slice(entries, func(i, j int) bool {
		if entries[i].Host == entries[j].Host {
			if entries[i].Mode == entries[j].Mode {
				return entries[i].Route < entries[j].Route
			}
			return entries[i].Mode < entries[j].Mode
		}
		return entries[i].Host < entries[j].Host
	})
	return entries
}

func configuredSNIRouteTarget(cfg runtime.Config, alias string) (backend, addr, healthKey string, ok bool) {
	switch strings.TrimSpace(alias) {
	case "http":
		return "http", cfg.HTTPBackendAddr(), "http", true
	case "vless_tcp":
		return "vless", cfg.VLESSRawBackendAddr(), "vless", true
	case "trojan_tcp":
		return "trojan", cfg.TrojanRawBackendAddr(), "trojan", true
	default:
		return "", "", "", false
	}
}

func (c *Collector) RenderPrometheus(cfg runtime.Config, listeners ListenerSnapshot) []byte {
	c.mu.Lock()
	counterKeys := make([]sampleKey, 0, len(c.counters))
	for key := range c.counters {
		counterKeys = append(counterKeys, key)
	}
	sort.Slice(counterKeys, func(i, j int) bool {
		if counterKeys[i].name == counterKeys[j].name {
			return counterKeys[i].labels < counterKeys[j].labels
		}
		return counterKeys[i].name < counterKeys[j].name
	})
	counterValues := make([]uint64, len(counterKeys))
	for i, key := range counterKeys {
		counterValues[i] = c.counters[key]
	}
	activeTotal := c.activeTotal
	activeKeys := make([]string, 0, len(c.activeBySurface))
	for key := range c.activeBySurface {
		activeKeys = append(activeKeys, key)
	}
	sort.Strings(activeKeys)
	activeValues := make([]int64, len(activeKeys))
	for i, key := range activeKeys {
		activeValues[i] = c.activeBySurface[key]
	}
	reloadSuccess := c.reloadSuccess
	lastReloadUnix := c.lastReloadUnix
	startedAt := c.startedAt
	var lastRoute *LastRouteSnapshot
	if c.lastRoute != nil {
		clone := *c.lastRoute
		lastRoute = &clone
	}
	c.mu.Unlock()

	var out bytes.Buffer
	writeSample(&out, "edge_mux_up", "", 1)
	writeSample(&out, "edge_mux_start_time_unix", "", startedAt.Unix())
	writeSample(&out, "edge_mux_uptime_seconds", "", int64(time.Since(startedAt).Seconds()))
	writeSample(&out, "edge_mux_metrics_enabled", "", boolInt(cfg.MetricsEnabled))
	writeSample(&out, "edge_mux_classic_tls_on_80", "", boolInt(cfg.ClassicTLSOn80))
	writeSample(&out, "edge_mux_accept_proxy_protocol", "", boolInt(cfg.AcceptProxyProtocol))
	writeSample(&out, "edge_mux_max_connections", "", cfg.MaxConnections)
	writeSample(&out, "edge_mux_max_connections_per_ip", "", cfg.MaxConnectionsPerIP)
	writeSample(&out, "edge_mux_accept_rate_limit_per_ip", "", cfg.AcceptRatePerIP)
	writeSample(&out, "edge_mux_accept_rate_window_seconds", "", int64(cfg.AcceptRateWindow/time.Second))
	writeSample(&out, "edge_mux_detect_timeout_milliseconds", "", int64(cfg.DetectTimeout/time.Millisecond))
	writeSample(&out, "edge_mux_tls_handshake_timeout_milliseconds", "", int64(cfg.TLSHandshakeTimeout/time.Millisecond))
	writeSample(&out, "edge_mux_tls_certificate_valid_from_unix", "", listeners.TLSCertValidFromUnix)
	writeSample(&out, "edge_mux_tls_certificate_expires_unix", "", listeners.TLSCertExpiresUnix)
	writeSample(&out, "edge_mux_reload_success_total", "", reloadSuccess)
	writeSample(&out, "edge_mux_last_reload_unix", "", lastReloadUnix)
	writeSample(&out, "edge_mux_connections_active_total", "", activeTotal)
	writeSample(&out, "edge_mux_listener_up", labels("surface", "http"), boolInt(listeners.HTTPUp))
	writeSample(&out, "edge_mux_listener_up", labels("surface", "tls"), boolInt(listeners.TLSUp))
	writeSample(&out, "edge_mux_listener_up", labels("surface", "metrics"), boolInt(listeners.MetricsUp))
	for i, surface := range activeKeys {
		writeSample(&out, "edge_mux_connections_active", labels("surface", surface), activeValues[i])
	}
	if lastRoute != nil && lastRoute.SeenAtUnix > 0 {
		writeSample(&out, "edge_mux_last_route_seen_unix", labels("surface", lastRoute.Surface, "route", lastRoute.Route, "backend", lastRoute.Backend, "alpn", fallback(lastRoute.ALPN, "none")), lastRoute.SeenAtUnix)
	}
	for i, key := range counterKeys {
		writeSample(&out, key.name, key.labels, counterValues[i])
	}
	return out.Bytes()
}

func parseLabelSet(labelSet string) map[string]string {
	out := make(map[string]string)
	labelSet = strings.TrimSpace(labelSet)
	if labelSet == "" {
		return out
	}
	for _, part := range strings.Split(labelSet, ",") {
		key, value, ok := strings.Cut(part, "=")
		if !ok {
			continue
		}
		key = strings.TrimSpace(key)
		value = strings.TrimSpace(value)
		value = strings.Trim(value, `"`)
		if key != "" {
			out[key] = value
		}
	}
	return out
}

func (c *Collector) incCounter(name, labelSet string) {
	c.addCounter(name, labelSet, 1)
}

func (c *Collector) addCounter(name, labelSet string, value uint64) {
	if value == 0 {
		return
	}
	c.mu.Lock()
	defer c.mu.Unlock()
	c.counters[sampleKey{name: name, labels: labelSet}] += value
}

func detectClassName(class detect.InitialClass) string {
	switch class {
	case detect.ClassHTTP:
		return "http"
	case detect.ClassTLSClientHello:
		return "tls_client_hello"
	case detect.ClassVLESSRaw:
		return "vless_raw"
	case detect.ClassTrojanRaw:
		return "trojan_raw"
	case detect.ClassTimeout:
		return "timeout"
	case detect.ClassPossibleHTTP:
		return "possible_http"
	default:
		return "unknown"
	}
}

func passthroughSurfaceFromContext(context string) string {
	context = strings.TrimSpace(context)
	if context == "" {
		return "unknown"
	}
	if surface, _, ok := strings.Cut(context, ":"); ok {
		surface = strings.TrimSpace(surface)
		if surface != "" {
			return surface
		}
	}
	return "unknown"
}

func labels(pairs ...string) string {
	if len(pairs) == 0 {
		return ""
	}
	var parts []string
	for i := 0; i+1 < len(pairs); i += 2 {
		key := strings.TrimSpace(pairs[i])
		if key == "" {
			continue
		}
		parts = append(parts, fmt.Sprintf(`%s="%s"`, key, escapeLabelValue(pairs[i+1])))
	}
	return strings.Join(parts, ",")
}

func escapeLabelValue(value string) string {
	replacer := strings.NewReplacer(`\`, `\\`, "\n", `\n`, `"`, `\"`)
	return replacer.Replace(value)
}

func writeSample(out *bytes.Buffer, name, labelSet string, value any) {
	if out == nil || name == "" {
		return
	}
	if labelSet == "" {
		fmt.Fprintf(out, "%s %v\n", name, value)
		return
	}
	fmt.Fprintf(out, "%s{%s} %v\n", name, labelSet, value)
}

func boolInt(value bool) int {
	if value {
		return 1
	}
	return 0
}

func truncate(value string, limit int) string {
	if limit <= 0 || len(value) <= limit {
		return value
	}
	if limit <= 3 {
		return value[:limit]
	}
	return value[:limit-3] + "..."
}

func fallback(value, alt string) string {
	if strings.TrimSpace(value) == "" {
		return alt
	}
	return value
}
