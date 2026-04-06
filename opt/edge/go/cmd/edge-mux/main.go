package main

import (
	"context"
	"crypto/tls"
	"errors"
	"flag"
	"fmt"
	"log"
	"net"
	"os"
	"os/signal"
	"sort"
	"strings"
	"sync"
	"sync/atomic"
	"syscall"
	"time"

	"github.com/superdecrypt-dev/autoscript/opt/edge/go/internal/abuse"
	"github.com/superdecrypt-dev/autoscript/opt/edge/go/internal/accounting"
	"github.com/superdecrypt-dev/autoscript/opt/edge/go/internal/detect"
	"github.com/superdecrypt-dev/autoscript/opt/edge/go/internal/ingress"
	"github.com/superdecrypt-dev/autoscript/opt/edge/go/internal/observability"
	"github.com/superdecrypt-dev/autoscript/opt/edge/go/internal/proxy"
	"github.com/superdecrypt-dev/autoscript/opt/edge/go/internal/routing"
	"github.com/superdecrypt-dev/autoscript/opt/edge/go/internal/runtime"
	"github.com/superdecrypt-dev/autoscript/opt/edge/go/internal/tlsmux"
)

type flagOverrides struct {
	httpListen        string
	tlsListen         string
	httpBackend       string
	xrayDirectBackend string
	certFile          string
	keyFile           string
	timeoutMs         int
}

const (
	reloadableListenerAcceptBuffer = 256
	reloadableListenerRetryDelay   = 100 * time.Millisecond
)

var errNoActiveListeners = errors.New("no active listeners")

func main() {
	overrides := parseFlagOverrides()
	loadConfig := func() (runtime.Config, error) {
		cfg, err := runtime.LoadConfig()
		if err != nil {
			return runtime.Config{}, err
		}
		overrides.Apply(&cfg)
		if err := cfg.Validate(); err != nil {
			return runtime.Config{}, err
		}
		return cfg, nil
	}

	cfg, err := loadConfig()
	if err != nil {
		log.Fatalf("edge-mux config error: %v", err)
	}

	logger := log.New(os.Stderr, "", log.LstdFlags)
	logger.Printf(
		"edge-mux starting provider=%s http=%s tls=%s metrics=%s metrics_enabled=%t http_backend=%s xray_direct_backend=%s xray_tls_backend=%s xray_ws_backend=%s xray_fallback_backend=%s vless_raw_backend=%s vless_source=%s trojan_raw_backend=%s trojan_source=%s sni_routes=%s sni_passthrough=%s timeout=%s tls_handshake_timeout=%s classic_tls_on_80=%t max_conns=%d max_conns_per_ip=%d accept_rate_per_ip=%d/%s cooldown=%d/%s/%s accept_proxy_protocol=%t",
		cfg.Provider,
		formatListenAddrs(cfg.HTTPListenAddrs()),
		formatListenAddrs(cfg.TLSListenAddrs()),
		cfg.MetricsAddr(),
		cfg.MetricsEnabled,
		cfg.HTTPBackendAddr(),
		cfg.XrayDirectBackendAddr(),
		cfg.XrayTLSBackendAddr(),
		cfg.XrayWSBackendAddr(),
		cfg.XrayFallbackBackendAddr(),
		cfg.VLESSRawBackendAddr(),
		cfg.VLESSRawSource,
		cfg.TrojanRawBackendAddr(),
		cfg.TrojanRawSource,
		formatSNIRoutes(cfg.SNIRoutes),
		formatSNIBackendMap(cfg.SNIPassthrough),
		cfg.DetectTimeout,
		cfg.TLSHandshakeTimeout,
		cfg.ClassicTLSOn80,
		cfg.MaxConnections,
		cfg.MaxConnectionsPerIP,
		cfg.AcceptRatePerIP,
		cfg.AcceptRateWindow,
		cfg.CooldownRejects,
		cfg.CooldownWindow,
		cfg.CooldownDuration,
		cfg.AcceptProxyProtocol,
	)

	live := runtime.NewLive(cfg)
	tlsState, err := newTLSState(cfg)
	if err != nil {
		log.Fatalf("edge-mux tls init error: %v", err)
	}

	httpListener, err := newReloadableListener(cfg.HTTPListenAddrs())
	if err != nil {
		log.Fatalf("edge-mux http listen error: %v", err)
	}
	tlsListener, err := newReloadableListener(cfg.TLSListenAddrs())
	if err != nil {
		_ = httpListener.Close()
		log.Fatalf("edge-mux tls listen error: %v", err)
	}

	ctx, stop := signal.NotifyContext(context.Background(), syscall.SIGINT, syscall.SIGTERM)
	defer stop()
	hupCh := make(chan os.Signal, 1)
	signal.Notify(hupCh, syscall.SIGHUP)
	defer signal.Stop(hupCh)

	go func() {
		<-ctx.Done()
		_ = httpListener.Close()
		_ = tlsListener.Close()
	}()

	logger.Printf("edge-mux http listeners ready on %s", formatListenAddrs(httpListener.Addrs()))
	logger.Printf("edge-mux tls listeners ready on %s", formatListenAddrs(tlsListener.Addrs()))

	guard := abuse.NewGuard()
	collector := observability.NewCollector(time.Now())
	backendHealth := newBackendHealthState(cfg)
	var metricsServer *observability.Server
	listenerState := func() observability.ListenerSnapshot {
		snapshot := observability.ListenerSnapshot{
			HTTPAddr: formatListenAddrs(httpListener.ActiveAddrs()),
			TLSAddr:  formatListenAddrs(tlsListener.ActiveAddrs()),
			HTTPUp:   httpListener.Healthy(),
			TLSUp:    tlsListener.Healthy(),
		}
		if metricsServer != nil {
			snapshot.MetricsAddr = metricsServer.Addr()
			snapshot.MetricsUp = metricsServer.Active()
		}
		if currentTLS := tlsState.Current(); currentTLS != nil {
			diag := currentTLS.Diagnostics()
			snapshot.TLSCertSubject = diag.CertificateSubject
			snapshot.TLSCertNotBefore = diag.CertificateNotBefore.Format(time.RFC3339)
			snapshot.TLSCertNotAfter = diag.CertificateNotAfter.Format(time.RFC3339)
			snapshot.TLSAdvertisedALPN = diag.AdvertisedALPN
			snapshot.TLSMinVersion = diag.MinVersion
			snapshot.TLSCertValidFromUnix = diag.CertificateNotBefore.Unix()
			snapshot.TLSCertExpiresUnix = diag.CertificateNotAfter.Unix()
		}
		return snapshot
	}
	metricsServer = observability.NewServer(
		logger,
		collector,
		live.Config,
		listenerState,
		func(current runtime.Config) map[string]observability.BackendHealthSnapshot {
			return backendHealth.Snapshot()
		},
		func() *observability.AbuseSnapshot {
			snapshot := guard.Snapshot()
			return &observability.AbuseSnapshot{
				ActiveIPs:         snapshot.ActiveIPs,
				ActiveConnections: snapshot.ActiveConnections,
				RateTrackedIPs:    snapshot.RateTrackedIPs,
				RejectTrackedIPs:  snapshot.RejectTrackedIPs,
				CooldownBlockedIP: snapshot.CooldownBlockedIP,
				BlockedUntilUnix:  snapshot.BlockedUntilUnix,
				BlockedReason:     snapshot.BlockedReason,
				BlockedSurface:    snapshot.BlockedSurface,
				RejectReasons:     snapshot.RejectReasons,
				RejectSurfaces:    snapshot.RejectSurfaces,
			}
		},
	)
	if err := metricsServer.Configure(cfg); err != nil {
		_ = httpListener.Close()
		_ = tlsListener.Close()
		log.Fatalf("edge-mux metrics init error: %v", err)
	}
	defer func() {
		_ = metricsServer.Close()
	}()

	var wg sync.WaitGroup
	errCh := make(chan error, 1)
	var fatalOnce sync.Once
	start := func(name string, fn func(context.Context) error) {
		wg.Add(1)
		go func() {
			defer wg.Done()
			if err := fn(ctx); err != nil && !errors.Is(err, context.Canceled) && !errors.Is(err, net.ErrClosed) {
				reportFatalError(errCh, &fatalOnce, name, err)
			}
		}()
	}

	start("http-listener", func(ctx context.Context) error {
		return serveHTTPMux(ctx, logger, live, tlsState, httpListener, guard, collector, backendHealth)
	})
	start("tls-listener", func(ctx context.Context) error {
		return serveTLSMux(ctx, logger, live, tlsState, tlsListener, guard, collector, backendHealth)
	})
	start("reload-loop", func(ctx context.Context) error {
		return handleReloads(ctx, logger, live, tlsState, httpListener, tlsListener, metricsServer, collector, backendHealth, loadConfig, hupCh)
	})
	start("backend-monitor", func(ctx context.Context) error {
		return monitorBackendState(ctx, logger, live, backendHealth)
	})

	select {
	case <-ctx.Done():
		logger.Printf("edge-mux stopping: %v", ctx.Err())
	case err := <-errCh:
		stop()
		logger.Printf("edge-mux fatal: %v", err)
	}

	wg.Wait()
}

func parseFlagOverrides() flagOverrides {
	var overrides flagOverrides
	bindFlagOverrides(flag.CommandLine, &overrides)
	flag.Parse()
	return overrides
}

func bindFlagOverrides(fs *flag.FlagSet, overrides *flagOverrides) {
	if fs == nil || overrides == nil {
		return
	}
	fs.StringVar(&overrides.httpListen, "http-listen", "", "public HTTP listen address")
	fs.StringVar(&overrides.tlsListen, "tls-listen", "", "public TLS listen address")
	fs.StringVar(&overrides.httpBackend, "http-backend", "", "internal HTTP backend address")
	fs.StringVar(&overrides.xrayDirectBackend, "xray-direct-backend", "", "internal Xray direct backend address")
	fs.StringVar(&overrides.certFile, "cert-file", "", "TLS certificate file")
	fs.StringVar(&overrides.keyFile, "key-file", "", "TLS key file")
	fs.IntVar(&overrides.timeoutMs, "detect-timeout-ms", 0, "initial protocol detect timeout in milliseconds")
}

func (o flagOverrides) Apply(cfg *runtime.Config) {
	if cfg == nil {
		return
	}
	if o.httpListen != "" {
		cfg.PublicHTTPAddr = o.httpListen
		cfg.PublicHTTPAddrs = []string{o.httpListen}
	}
	if o.tlsListen != "" {
		cfg.PublicTLSAddr = o.tlsListen
		cfg.PublicTLSAddrs = []string{o.tlsListen}
	}
	if o.httpBackend != "" {
		cfg.HTTPBackend = o.httpBackend
	}
	if o.xrayDirectBackend != "" {
		cfg.XrayDirectBackend = o.xrayDirectBackend
	}
	if o.certFile != "" {
		cfg.TLSCertFile = o.certFile
	}
	if o.keyFile != "" {
		cfg.TLSKeyFile = o.keyFile
	}
	if o.timeoutMs > 0 {
		cfg.DetectTimeout = time.Duration(o.timeoutMs) * time.Millisecond
	}
}

type tlsState struct {
	current atomic.Pointer[tlsmux.Server]
}

func newTLSState(cfg runtime.Config) (*tlsState, error) {
	state := &tlsState{}
	if err := state.Reload(cfg); err != nil {
		return nil, err
	}
	return state, nil
}

func (s *tlsState) Current() *tlsmux.Server {
	if s == nil {
		return nil
	}
	return s.current.Load()
}

func (s *tlsState) Reload(cfg runtime.Config) error {
	if s == nil {
		return nil
	}
	server, err := tlsmux.NewServer(cfg)
	if err != nil {
		return err
	}
	s.current.Store(server)
	return nil
}

type reloadableListener struct {
	mu        sync.RWMutex
	listeners map[string]net.Listener
	addrs     []string
	active    map[string]bool
	acceptCh  chan acceptResult
	closeCh   chan struct{}
	closeOnce sync.Once
}

type acceptResult struct {
	conn net.Conn
	err  error
}

func newReloadableListener(addrs []string) (*reloadableListener, error) {
	l := &reloadableListener{
		listeners: make(map[string]net.Listener),
		active:    make(map[string]bool),
		acceptCh:  make(chan acceptResult, reloadableListenerAcceptBuffer),
		closeCh:   make(chan struct{}),
	}
	if err := l.Reconcile(addrs); err != nil {
		return nil, err
	}
	return l, nil
}

func (l *reloadableListener) Addr() string {
	l.mu.RLock()
	defer l.mu.RUnlock()
	if len(l.addrs) == 0 {
		return ""
	}
	return l.addrs[0]
}

func (l *reloadableListener) Addrs() []string {
	l.mu.RLock()
	defer l.mu.RUnlock()
	return append([]string(nil), l.addrs...)
}

func (l *reloadableListener) ActiveAddrs() []string {
	l.mu.RLock()
	defer l.mu.RUnlock()
	out := make([]string, 0, len(l.addrs))
	for _, addr := range l.addrs {
		if l.active[addr] {
			out = append(out, addr)
		}
	}
	return out
}

func (l *reloadableListener) Healthy() bool {
	l.mu.RLock()
	defer l.mu.RUnlock()
	if len(l.addrs) == 0 {
		return false
	}
	for _, addr := range l.addrs {
		if !l.active[addr] {
			return false
		}
	}
	return true
}

func (l *reloadableListener) Accept(ctx context.Context) (net.Conn, error) {
	for {
		select {
		case <-ctx.Done():
			return nil, ctx.Err()
		case <-l.closeCh:
			return nil, net.ErrClosed
		case result, ok := <-l.acceptCh:
			if !ok {
				return nil, net.ErrClosed
			}
			if result.err != nil {
				if ctx.Err() != nil {
					return nil, ctx.Err()
				}
				continue
			}
			if result.conn != nil {
				return result.conn, nil
			}
		case <-time.After(reloadableListenerRetryDelay):
			if l.allListenersInactive() {
				return nil, errNoActiveListeners
			}
		}
	}
}

func (l *reloadableListener) Reconcile(addrs []string) error {
	desired := normalizeListenAddrs(addrs)
	if len(desired) == 0 {
		return errors.New("listener set must not be empty")
	}

	l.mu.RLock()
	current := make(map[string]net.Listener, len(l.listeners))
	for addr, ln := range l.listeners {
		current[addr] = ln
	}
	currentActive := make(map[string]bool, len(l.active))
	for addr, active := range l.active {
		currentActive[addr] = active
	}
	l.mu.RUnlock()

	newlyCreated := make(map[string]net.Listener)
	for _, addr := range desired {
		if ln, ok := current[addr]; ok && currentActive[addr] {
			_ = ln
			continue
		}
		if ln, ok := current[addr]; ok && !currentActive[addr] {
			_ = ln.Close()
		}
		ln, err := net.Listen("tcp", addr)
		if err != nil {
			for _, created := range newlyCreated {
				_ = created.Close()
			}
			return err
		}
		newlyCreated[addr] = ln
	}

	next := make(map[string]net.Listener, len(desired))
	nextActive := make(map[string]bool, len(desired))
	for _, addr := range desired {
		if ln, ok := current[addr]; ok && currentActive[addr] && newlyCreated[addr] == nil {
			next[addr] = ln
			nextActive[addr] = true
			continue
		}
		next[addr] = newlyCreated[addr]
		nextActive[addr] = true
	}

	l.mu.Lock()
	old := l.listeners
	l.listeners = next
	l.addrs = append([]string(nil), desired...)
	l.active = nextActive
	l.mu.Unlock()

	for addr, ln := range newlyCreated {
		l.serveAcceptLoop(addr, ln)
	}
	for addr, ln := range old {
		if currentNext, ok := next[addr]; !ok || currentNext != ln {
			_ = ln.Close()
		}
	}
	return nil
}

func (l *reloadableListener) Close() error {
	l.mu.Lock()
	oldListeners := l.listeners
	l.listeners = nil
	l.addrs = nil
	l.active = nil
	l.mu.Unlock()

	l.closeOnce.Do(func() {
		close(l.closeCh)
	})

	var firstErr error
	for _, ln := range oldListeners {
		if err := ln.Close(); err != nil && !errors.Is(err, net.ErrClosed) && firstErr == nil {
			firstErr = err
		}
	}
	return firstErr
}

func (l *reloadableListener) serveAcceptLoop(addr string, ln net.Listener) {
	go func() {
		for {
			conn, err := ln.Accept()
			if err != nil {
				if errors.Is(err, net.ErrClosed) {
					l.markListenerInactive(addr, ln)
					return
				}
				if !l.listenerStillActive(addr, ln) {
					return
				}
				if !isRetryableAcceptError(err) {
					l.markListenerInactive(addr, ln)
					l.deliverAcceptError(err)
					return
				}
				l.deliverAcceptError(err)
				select {
				case <-time.After(reloadableListenerRetryDelay):
				case <-l.closeCh:
					return
				}
				continue
			}
			if !l.deliverAcceptedConn(conn) {
				return
			}
		}
	}()
}

func (l *reloadableListener) deliverAcceptError(err error) {
	select {
	case l.acceptCh <- acceptResult{err: err}:
	case <-l.closeCh:
	default:
	}
}

func (l *reloadableListener) deliverAcceptedConn(conn net.Conn) bool {
	select {
	case l.acceptCh <- acceptResult{conn: conn}:
		return true
	case <-l.closeCh:
		_ = conn.Close()
		return false
	}
}

func (l *reloadableListener) listenerStillActive(addr string, ln net.Listener) bool {
	l.mu.RLock()
	defer l.mu.RUnlock()
	current, ok := l.listeners[addr]
	return ok && current == ln
}

func (l *reloadableListener) listenerActive(addr string) bool {
	l.mu.RLock()
	defer l.mu.RUnlock()
	return l.active[addr]
}

func (l *reloadableListener) markListenerInactive(addr string, ln net.Listener) {
	l.mu.Lock()
	defer l.mu.Unlock()
	current, ok := l.listeners[addr]
	if !ok || current != ln {
		return
	}
	l.active[addr] = false
}

func (l *reloadableListener) allListenersInactive() bool {
	l.mu.RLock()
	defer l.mu.RUnlock()
	if len(l.addrs) == 0 {
		return false
	}
	for _, addr := range l.addrs {
		if l.active[addr] {
			return false
		}
	}
	return true
}

func normalizeListenAddrs(addrs []string) []string {
	out := make([]string, 0, len(addrs))
	seen := make(map[string]struct{}, len(addrs))
	for _, addr := range addrs {
		text := strings.TrimSpace(addr)
		if text == "" {
			continue
		}
		if _, ok := seen[text]; ok {
			continue
		}
		seen[text] = struct{}{}
		out = append(out, text)
	}
	return out
}

func formatListenAddrs(addrs []string) string {
	if len(addrs) == 0 {
		return "-"
	}
	return strings.Join(addrs, ",")
}

func isRetryableAcceptError(err error) bool {
	if err == nil {
		return false
	}
	var netErr net.Error
	if errors.As(err, &netErr) {
		if netErr.Timeout() {
			return true
		}
	}
	type temporaryError interface {
		Temporary() bool
	}
	var tempErr temporaryError
	if errors.As(err, &tempErr) {
		return tempErr.Temporary()
	}
	return false
}

func reportFatalError(errCh chan<- error, once *sync.Once, name string, err error) {
	if err == nil || once == nil {
		return
	}
	once.Do(func() {
		select {
		case errCh <- errors.New(name + ": " + err.Error()):
		default:
		}
	})
}

func rollbackReloadState(
	oldCfg runtime.Config,
	tlsLive *tlsState,
	httpListener *reloadableListener,
	tlsListener *reloadableListener,
	metricsServer *observability.Server,
) error {
	if metricsServer != nil {
		if err := metricsServer.Configure(oldCfg); err != nil {
			return fmt.Errorf("metrics: %w", err)
		}
	}
	if tlsListener != nil {
		if err := tlsListener.Reconcile(oldCfg.TLSListenAddrs()); err != nil {
			return fmt.Errorf("tls listeners: %w", err)
		}
	}
	if httpListener != nil {
		if err := httpListener.Reconcile(oldCfg.HTTPListenAddrs()); err != nil {
			return fmt.Errorf("http listeners: %w", err)
		}
	}
	if tlsLive != nil {
		if err := tlsLive.Reload(oldCfg); err != nil {
			return fmt.Errorf("tls state: %w", err)
		}
	}
	return nil
}

func handleReloads(
	ctx context.Context,
	logger *log.Logger,
	live *runtime.Live,
	tlsLive *tlsState,
	httpListener *reloadableListener,
	tlsListener *reloadableListener,
	metricsServer *observability.Server,
	collector *observability.Collector,
	backendHealth *backendHealthState,
	loadConfig func() (runtime.Config, error),
	hupCh <-chan os.Signal,
) error {
	for {
		select {
		case <-ctx.Done():
			return nil
		case <-hupCh:
		}

		oldCfg := live.Config()
		newCfg, err := loadConfig()
		if err != nil {
			collector.ObserveReloadFailure("config")
			logger.Printf("edge-mux reload rejected: %v", err)
			continue
		}
		if err := tlsLive.Reload(newCfg); err != nil {
			collector.ObserveReloadFailure("tls")
			logger.Printf("edge-mux reload tls failed: %v", err)
			continue
		}
		if err := httpListener.Reconcile(newCfg.HTTPListenAddrs()); err != nil {
			collector.ObserveReloadFailure("http_listener")
			logger.Printf("edge-mux reload http listeners failed addrs=%s: %v", formatListenAddrs(newCfg.HTTPListenAddrs()), err)
			if rollbackErr := rollbackReloadState(oldCfg, tlsLive, nil, nil, nil); rollbackErr != nil {
				return fmt.Errorf("reload rollback failed after http listener error: %w", rollbackErr)
			}
			continue
		}
		if err := tlsListener.Reconcile(newCfg.TLSListenAddrs()); err != nil {
			collector.ObserveReloadFailure("tls_listener")
			logger.Printf("edge-mux reload tls listeners failed addrs=%s: %v", formatListenAddrs(newCfg.TLSListenAddrs()), err)
			if rollbackErr := rollbackReloadState(oldCfg, tlsLive, httpListener, nil, nil); rollbackErr != nil {
				return fmt.Errorf("reload rollback failed after tls listener error: %w", rollbackErr)
			}
			continue
		}
		if err := metricsServer.Configure(newCfg); err != nil {
			collector.ObserveReloadFailure("metrics")
			logger.Printf("edge-mux reload metrics reconfigure failed addr=%s: %v", newCfg.MetricsAddr(), err)
			if rollbackErr := rollbackReloadState(oldCfg, tlsLive, httpListener, tlsListener, metricsServer); rollbackErr != nil {
				return fmt.Errorf("reload rollback failed after metrics error: %w", rollbackErr)
			}
			continue
		}
		live.Set(newCfg)
		if backendHealth != nil {
			backendHealth.Refresh(newCfg)
		}
		collector.ObserveReloadSuccess()
		logger.Printf(
			"edge-mux reloaded http=%s tls=%s metrics=%s metrics_enabled=%t http_backend=%s xray_direct_backend=%s vless_raw_backend=%s vless_source=%s trojan_raw_backend=%s trojan_source=%s sni_routes=%s sni_passthrough=%s timeout=%s tls_handshake_timeout=%s classic_tls_on_80=%t",
			formatListenAddrs(newCfg.HTTPListenAddrs()),
			formatListenAddrs(newCfg.TLSListenAddrs()),
			newCfg.MetricsAddr(),
			newCfg.MetricsEnabled,
			newCfg.HTTPBackendAddr(),
			newCfg.XrayDirectBackendAddr(),
			newCfg.VLESSRawBackendAddr(),
			newCfg.VLESSRawSource,
			newCfg.TrojanRawBackendAddr(),
			newCfg.TrojanRawSource,
			formatSNIRoutes(newCfg.SNIRoutes),
			formatSNIBackendMap(newCfg.SNIPassthrough),
			newCfg.DetectTimeout,
			newCfg.TLSHandshakeTimeout,
			newCfg.ClassicTLSOn80,
		)
	}
}

func serveHTTPMux(
	ctx context.Context,
	logger *log.Logger,
	live *runtime.Live,
	tlsLive *tlsState,
	listener *reloadableListener,
	guard *abuse.Guard,
	collector *observability.Collector,
	backendHealth *backendHealthState,
) error {
	for {
		conn, err := listener.Accept(ctx)
		if err != nil {
			if ctx.Err() != nil {
				return nil
			}
			return err
		}
		cfg := live.Config()
		wrapped, err := ingress.Wrap(conn, cfg.AcceptProxyProtocol, cfg.TrustedProxyCIDRs, cfg.DetectTimeout)
		if err != nil {
			collector.ObserveIngressWrapError("http-port")
			logger.Printf("edge-mux ingress wrap failed surface=http-port remote=%s err=%v", safeRemote(conn), err)
			_ = conn.Close()
			continue
		}
		go handleHTTPPortConn(logger, cfg, tlsLive.Current(), guard, collector, backendHealth, wrapped)
	}
}

func serveTLSMux(
	ctx context.Context,
	logger *log.Logger,
	live *runtime.Live,
	tlsLive *tlsState,
	listener *reloadableListener,
	guard *abuse.Guard,
	collector *observability.Collector,
	backendHealth *backendHealthState,
) error {
	for {
		conn, err := listener.Accept(ctx)
		if err != nil {
			if ctx.Err() != nil {
				return nil
			}
			return err
		}
		cfg := live.Config()
		wrapped, err := ingress.Wrap(conn, cfg.AcceptProxyProtocol, cfg.TrustedProxyCIDRs, cfg.DetectTimeout)
		if err != nil {
			collector.ObserveIngressWrapError("tls-port")
			logger.Printf("edge-mux ingress wrap failed surface=tls-port remote=%s err=%v", safeRemote(conn), err)
			_ = conn.Close()
			continue
		}
		go handleTLSPortConn(logger, cfg, tlsLive.Current(), guard, collector, backendHealth, wrapped)
	}
}

func bridgeToBackend(logger *log.Logger, cfg runtime.Config, collector *observability.Collector, health *backendHealthState, left net.Conn, target string, leftPrefix []byte, contextLabel string, sendHTTP502 bool) {
	started := time.Now()
	backend, err := net.DialTimeout("tcp", target, 5*time.Second)
	if err != nil {
		collector.ObserveBackendDialFailure(backendLabel(cfg, target), contextLabel)
		if health != nil {
			health.MarkDialFailure(backendHealthKey(cfg, target), target, err)
		}
		logger.Printf("edge-mux backend dial failed target=%s context=%s: %v", target, contextLabel, err)
		if sendHTTP502 {
			_ = writeHTTPError(left, 502, "Bad Gateway")
		}
		return
	}
	defer backend.Close()
	if health != nil {
		health.MarkDialSuccess(backendHealthKey(cfg, target), target, time.Since(started))
	}
	leftPrefix = backendIngressPrefix(cfg, target, left, leftPrefix)

	var stats proxy.BridgeStats
	if target == cfg.XrayDirectBackendAddr() {
		quotaCfg := xrayQuotaConfig(cfg)
		if tcpAddr, ok := backend.LocalAddr().(*net.TCPAddr); ok {
			speedCtl := accounting.NewXraySpeedController(logger, quotaCfg, tcpAddr.Port)
			speedCtl.Start()
			defer speedCtl.Stop()
			speedCtl.WaitForInitialPolicy(0)
			sessionTracker := accounting.NewXrayRuntimeSessionTracker(logger, quotaCfg, tcpAddr.Port, safeRemote(left), contextLabel, func() string {
				return speedCtl.Username()
			})
			if sessionTracker != nil {
				sessionTracker.Start()
				defer sessionTracker.Stop()
			}
			stats, err = proxy.BridgeWithStatsAndOptions(left, backend, leftPrefix, nil, proxy.BridgeOptions{
				LeftToRight: speedCtl.UploadLimiter(),
				RightToLeft: speedCtl.DownloadLimiter(),
			})
			collector.ObserveBridgeBytes(contextLabel, stats.LeftToRight, stats.RightToLeft)
			speedCtl.WaitForReady(stats.LeftToRight + stats.RightToLeft)
			accounting.RecordXrayQuota(logger, quotaCfg, speedCtl.Username(), tcpAddr.Port, stats.LeftToRight+stats.RightToLeft)
			if err != nil {
				collector.ObserveBridgeError(contextLabel)
				logger.Printf("edge-mux bridge error target=%s context=%s: %v", target, contextLabel, err)
			}
			return
		}
	}

	var sessionTracker *accounting.XrayRuntimeSessionTracker
	if target == cfg.XrayDirectBackendAddr() {
		quotaCfg := xrayQuotaConfig(cfg)
		if tcpAddr, ok := backend.LocalAddr().(*net.TCPAddr); ok {
			sessionTracker = accounting.NewXrayRuntimeSessionTracker(logger, quotaCfg, tcpAddr.Port, safeRemote(left), contextLabel, nil)
			if sessionTracker != nil {
				sessionTracker.Start()
				defer sessionTracker.Stop()
			}
		}
	}

	stats, err = proxy.BridgeWithStats(left, backend, leftPrefix, nil)
	collector.ObserveBridgeBytes(contextLabel, stats.LeftToRight, stats.RightToLeft)
	if target == cfg.XrayDirectBackendAddr() {
		quotaCfg := xrayQuotaConfig(cfg)
		if tcpAddr, ok := backend.LocalAddr().(*net.TCPAddr); ok {
			accounting.RecordXrayQuotaByLocalPort(logger, quotaCfg, tcpAddr.Port, stats.LeftToRight+stats.RightToLeft)
		}
	}
	if err != nil {
		collector.ObserveBridgeError(contextLabel)
		logger.Printf("edge-mux bridge error target=%s context=%s: %v", target, contextLabel, err)
	}
}

func backendIngressPrefix(cfg runtime.Config, target string, left net.Conn, payload []byte) []byte {
	if !shouldSendProxyHeader(cfg, target) {
		return payload
	}
	header := buildProxyV1Header(left)
	if len(header) == 0 {
		return payload
	}
	if len(payload) == 0 {
		return header
	}
	merged := make([]byte, 0, len(header)+len(payload))
	merged = append(merged, header...)
	merged = append(merged, payload...)
	return merged
}

func shouldSendProxyHeader(cfg runtime.Config, target string) bool {
	switch target {
	case cfg.HTTPBackendAddr(), cfg.VLESSRawBackendAddr(), cfg.TrojanRawBackendAddr():
		return true
	default:
		return false
	}
}

func buildProxyV1Header(conn net.Conn) []byte {
	if conn == nil {
		return nil
	}
	srcIP, srcPort, srcVer, ok := splitProxyAddr(conn.RemoteAddr())
	if !ok {
		return nil
	}
	dstIP, dstPort, dstVer, ok := splitProxyAddr(conn.LocalAddr())
	if !ok || srcVer != dstVer {
		return nil
	}
	family := "TCP4"
	if srcVer == 6 {
		family = "TCP6"
	}
	return []byte(fmt.Sprintf("PROXY %s %s %s %d %d\r\n", family, srcIP, dstIP, srcPort, dstPort))
}

func splitProxyAddr(addr net.Addr) (string, int, int, bool) {
	tcpAddr, ok := addr.(*net.TCPAddr)
	if ok && tcpAddr != nil && tcpAddr.IP != nil {
		ip := tcpAddr.IP
		if ip4 := ip.To4(); ip4 != nil {
			return ip4.String(), tcpAddr.Port, 4, true
		}
		if ip16 := ip.To16(); ip16 != nil {
			return ip16.String(), tcpAddr.Port, 6, true
		}
	}
	host, portText, err := net.SplitHostPort(strings.TrimSpace(fmt.Sprint(addr)))
	if err != nil {
		return "", 0, 0, false
	}
	ip := net.ParseIP(strings.Trim(host, "[]"))
	if ip == nil {
		return "", 0, 0, false
	}
	port, err := net.LookupPort("tcp", portText)
	if err != nil {
		return "", 0, 0, false
	}
	if ip4 := ip.To4(); ip4 != nil {
		return ip4.String(), port, 4, true
	}
	return ip.String(), port, 6, true
}

func handleHTTPPortConn(logger *log.Logger, cfg runtime.Config, tlsServer *tlsmux.Server, guard *abuse.Guard, collector *observability.Collector, health *backendHealthState, conn net.Conn) {
	defer conn.Close()
	release, ok := admitConn(logger, guard, collector, cfg, conn, "http-port")
	if !ok {
		return
	}
	defer release()

	initial, class, err := detect.ReadInitial(conn, cfg.DetectTimeout, detect.MaxPeekBytes)
	if err != nil {
		collector.ObserveReadInitialError("http-port")
		logger.Printf("edge-mux http read initial failed from %s: %v", safeRemote(conn), err)
		return
	}
	collector.ObserveDetect("http-port", class)

	switch class {
	case detect.ClassHTTP:
		decision := decideHTTPRoute(cfg, "http-port", initial, "", "", remoteIsLoopback(conn))
		event := routeDecisionEvent(cfg, health, class, decision.Backend, decision.Route, decision.Host, decision.Path, decision.ALPN, decision.SNI, "", decision.Status, "detect", "")
		event.Surface = "http-port"
		if decision.Status > 0 {
			emitRouteDecision(logger, collector, conn, event)
			_ = writeHTTPError(conn, decision.Status, decision.Text)
			return
		}
		if snapshot, blocked := routeBlockedByHealth(health, cfg, decision.Backend); blocked {
			emitBlockedRoute(logger, collector, conn, event, snapshot, true)
			return
		}
		emitRouteDecision(logger, collector, conn, event)
		bridgeToBackend(logger, cfg, collector, health, conn, decision.Backend, initial, decision.Context, true)
		return
	case detect.ClassTLSClientHello:
		if !cfg.ClassicTLSOn80 || tlsServer == nil {
			logger.Printf("edge-mux tls-on-80 disabled for %s", safeRemote(conn))
			return
		}
		tlsConn, err := tlsServer.AcceptBufferedTLSConn(conn, initial)
		if err != nil {
			collector.ObserveTLSHandshakeFailure("http-port")
			guard.ObserveFailure(cfg, conn.RemoteAddr(), "http-port", "tls_handshake")
			logger.Printf("edge-mux tls-on-80 handshake failed: %v", err)
			return
		}
		defer tlsConn.Close()
		handleTLSPayloadConn(logger, cfg, collector, health, tlsConn, "http-inner")
		return
	case detect.ClassVLESSRaw:
		event := routeDecisionEvent(cfg, health, class, cfg.VLESSRawBackendAddr(), "vless-tcp", "", "", "", "", "", 0, "detect", "")
		event.Surface = "http-port"
		if snapshot, blocked := routeBlockedByHealth(health, cfg, cfg.VLESSRawBackendAddr()); blocked {
			emitBlockedRoute(logger, collector, conn, event, snapshot, false)
			return
		}
		emitRouteDecision(logger, collector, conn, event)
		bridgeToBackend(logger, cfg, collector, health, conn, cfg.VLESSRawBackendAddr(), initial, "http-port:vless-tcp", false)
		return
	case detect.ClassTrojanRaw:
		event := routeDecisionEvent(cfg, health, class, cfg.TrojanRawBackendAddr(), "trojan-tcp", "", "", "", "", "", 0, "detect", "")
		event.Surface = "http-port"
		if snapshot, blocked := routeBlockedByHealth(health, cfg, cfg.TrojanRawBackendAddr()); blocked {
			emitBlockedRoute(logger, collector, conn, event, snapshot, false)
			return
		}
		emitRouteDecision(logger, collector, conn, event)
		bridgeToBackend(logger, cfg, collector, health, conn, cfg.TrojanRawBackendAddr(), initial, "http-port:trojan-tcp", false)
		return
	case detect.ClassTimeout:
		event := routeDecisionEvent(cfg, health, class, cfg.XrayDirectBackendAddr(), "xray-direct-timeout", "", "", "", "", "", 0, "detect", "")
		event.Surface = "http-port"
		if snapshot, blocked := routeBlockedByHealth(health, cfg, cfg.XrayDirectBackendAddr()); blocked {
			emitBlockedRoute(logger, collector, conn, event, snapshot, false)
			return
		}
		emitRouteDecision(logger, collector, conn, event)
		bridgeToBackend(logger, cfg, collector, health, conn, cfg.XrayDirectBackendAddr(), nil, "http-port:xray-direct-timeout", false)
		return
	case detect.ClassPossibleHTTP:
		logger.Printf("edge-mux http port timed out with partial http request from %s", safeRemote(conn))
		_ = writeHTTPError(conn, 408, "Request Timeout")
		return
	default:
		event := routeDecisionEvent(cfg, health, class, cfg.XrayDirectBackendAddr(), "xray-direct-unknown", "", "", "", "", "", 0, "detect", "")
		event.Surface = "http-port"
		if snapshot, blocked := routeBlockedByHealth(health, cfg, cfg.XrayDirectBackendAddr()); blocked {
			emitBlockedRoute(logger, collector, conn, event, snapshot, false)
			return
		}
		emitRouteDecision(logger, collector, conn, event)
		bridgeToBackend(logger, cfg, collector, health, conn, cfg.XrayDirectBackendAddr(), initial, "http-port:xray-direct-unknown", false)
	}
}

func handleTLSPortConn(logger *log.Logger, cfg runtime.Config, server *tlsmux.Server, guard *abuse.Guard, collector *observability.Collector, health *backendHealthState, conn net.Conn) {
	defer conn.Close()
	release, ok := admitConn(logger, guard, collector, cfg, conn, "tls-port")
	if !ok {
		return
	}
	defer release()

	initial, class, err := detect.ReadInitial(conn, cfg.DetectTimeout, detect.MaxPeekBytes)
	if err != nil {
		collector.ObserveReadInitialError("tls-port")
		logger.Printf("edge-mux public tls/raw read initial failed from %s: %v", safeRemote(conn), err)
		return
	}
	collector.ObserveDetect("tls-port", class)

	switch class {
	case detect.ClassTLSClientHello:
		sni, _ := detect.ExtractTLSServerName(initial)
		if decision, ok := resolveSNIPassthroughDecision(cfg, sni, "tls-port"); ok {
			event := routeDecisionEvent(cfg, health, class, decision.target, decision.route, "", "", "", sni, decision.reason, 0, decision.routeSource, decision.matchedRoute)
			event.Surface = "tls-port"
			if snapshot, blocked := routeBlockedByHealth(health, cfg, decision.target); blocked {
				emitBlockedRoute(logger, collector, conn, event, snapshot, false)
				return
			}
			emitRouteDecision(logger, collector, conn, event)
			bridgeToBackend(logger, cfg, collector, health, conn, decision.target, initial, decision.contextLabel, false)
			return
		}
		if server == nil {
			logger.Printf("edge-mux tls server unavailable for %s", safeRemote(conn))
			return
		}
		tlsConn, err := server.AcceptBufferedTLSConn(conn, initial)
		if err != nil {
			collector.ObserveTLSHandshakeFailure("tls-port")
			guard.ObserveFailure(cfg, conn.RemoteAddr(), "tls-port", "tls_handshake")
			logger.Printf("edge-mux tls handshake failed from %s: %v", safeRemote(conn), err)
			return
		}
		defer tlsConn.Close()
		handleTLSPayloadConn(logger, cfg, collector, health, tlsConn, "tls-inner")
		return
	case detect.ClassHTTP:
		decision := decideHTTPRoute(cfg, "tls-port-plaintext", initial, "", "", remoteIsLoopback(conn))
		event := routeDecisionEvent(cfg, health, class, decision.Backend, decision.Route, decision.Host, decision.Path, decision.ALPN, decision.SNI, "", decision.Status, "detect", "")
		event.Surface = "tls-port-plaintext"
		if decision.Status > 0 {
			emitRouteDecision(logger, collector, conn, event)
			_ = writeHTTPError(conn, decision.Status, decision.Text)
			return
		}
		if snapshot, blocked := routeBlockedByHealth(health, cfg, decision.Backend); blocked {
			emitBlockedRoute(logger, collector, conn, event, snapshot, true)
			return
		}
		emitRouteDecision(logger, collector, conn, event)
		bridgeToBackend(logger, cfg, collector, health, conn, decision.Backend, initial, decision.Context, true)
		return
	case detect.ClassPossibleHTTP:
		logger.Printf("edge-mux tls port timed out with partial plaintext http request from %s", safeRemote(conn))
		_ = writeHTTPError(conn, 408, "Request Timeout")
		return
	case detect.ClassVLESSRaw:
		event := routeDecisionEvent(cfg, health, class, cfg.VLESSRawBackendAddr(), "vless-tcp", "", "", "", "", "", 0, "detect", "")
		event.Surface = "tls-port"
		if snapshot, blocked := routeBlockedByHealth(health, cfg, cfg.VLESSRawBackendAddr()); blocked {
			emitBlockedRoute(logger, collector, conn, event, snapshot, false)
			return
		}
		emitRouteDecision(logger, collector, conn, event)
		bridgeToBackend(logger, cfg, collector, health, conn, cfg.VLESSRawBackendAddr(), initial, "tls-port:vless-tcp", false)
		return
	case detect.ClassTrojanRaw:
		event := routeDecisionEvent(cfg, health, class, cfg.TrojanRawBackendAddr(), "trojan-tcp", "", "", "", "", "", 0, "detect", "")
		event.Surface = "tls-port"
		if snapshot, blocked := routeBlockedByHealth(health, cfg, cfg.TrojanRawBackendAddr()); blocked {
			emitBlockedRoute(logger, collector, conn, event, snapshot, false)
			return
		}
		emitRouteDecision(logger, collector, conn, event)
		bridgeToBackend(logger, cfg, collector, health, conn, cfg.TrojanRawBackendAddr(), initial, "tls-port:trojan-tcp", false)
		return
	case detect.ClassTimeout:
		event := routeDecisionEvent(cfg, health, class, cfg.XrayDirectBackendAddr(), "xray-direct-timeout", "", "", "", "", "", 0, "detect", "")
		event.Surface = "tls-port"
		if snapshot, blocked := routeBlockedByHealth(health, cfg, cfg.XrayDirectBackendAddr()); blocked {
			emitBlockedRoute(logger, collector, conn, event, snapshot, false)
			return
		}
		emitRouteDecision(logger, collector, conn, event)
		bridgeToBackend(logger, cfg, collector, health, conn, cfg.XrayDirectBackendAddr(), nil, "tls-port:xray-direct-timeout", false)
		return
	default:
		event := routeDecisionEvent(cfg, health, class, cfg.XrayDirectBackendAddr(), "xray-direct-unknown", "", "", "", "", "", 0, "detect", "")
		event.Surface = "tls-port"
		if snapshot, blocked := routeBlockedByHealth(health, cfg, cfg.XrayDirectBackendAddr()); blocked {
			emitBlockedRoute(logger, collector, conn, event, snapshot, false)
			return
		}
		emitRouteDecision(logger, collector, conn, event)
		bridgeToBackend(logger, cfg, collector, health, conn, cfg.XrayDirectBackendAddr(), initial, "tls-port:xray-direct-unknown", false)
		return
	}
}

func handleTLSPayloadConn(logger *log.Logger, cfg runtime.Config, collector *observability.Collector, health *backendHealthState, tlsConn net.Conn, surface string) {
	initial, class, err := detect.ReadInitial(tlsConn, cfg.DetectTimeout, detect.MaxPeekBytes)
	if err != nil {
		collector.ObserveReadInitialError(surface)
		logger.Printf("edge-mux tls read initial failed from %s: %v", safeRemote(tlsConn), err)
		return
	}
	collector.ObserveDetect(surface, class)
	alpn := negotiatedALPN(tlsConn)
	sni := negotiatedSNI(tlsConn)
	decision := decideTLSPayloadRoute(cfg, surface, initial, class, alpn, sni, remoteIsLoopback(tlsConn))
	if decision.status == 408 {
		logger.Printf("edge-mux tls request timed out with partial http request from %s", safeRemote(tlsConn))
		_ = writeHTTPError(tlsConn, 408, "Request Timeout")
		return
	}
	event := routeDecisionEvent(cfg, health, class, decision.target, decision.route, decision.host, decision.path, alpn, sni, decision.reason, decision.status, decision.routeSource, decision.matchedRoute)
	event.Surface = surface
	if decision.status > 0 {
		emitRouteDecision(logger, collector, tlsConn, event)
		_ = writeHTTPError(tlsConn, decision.status, decision.reason)
		return
	}
	if snapshot, blocked := routeBlockedByHealth(health, cfg, decision.target); blocked {
		emitBlockedRoute(logger, collector, tlsConn, event, snapshot, decision.sendHTTP502)
		return
	}
	emitRouteDecision(logger, collector, tlsConn, event)
	bridgeToBackend(logger, cfg, collector, health, tlsConn, decision.target, initial, decision.contextLabel, decision.sendHTTP502)
}

type tlsRouteDecision struct {
	target       string
	contextLabel string
	route        string
	routeSource  string
	matchedRoute string
	host         string
	path         string
	reason       string
	status       int
	sendHTTP502  bool
}

func decideTLSPayloadRoute(cfg runtime.Config, surface string, initial []byte, class detect.InitialClass, alpn, sni string, allowDiagnostic bool) tlsRouteDecision {
	if decision, ok := resolveSNIRouteDecision(cfg, sni, surface); ok {
		if req, parsed := routing.ParseHTTPRequest(initial); parsed {
			decision.host = req.Host
			decision.path = req.Path
		}
		return decision
	}

	decision := tlsRouteDecision{
		target:       cfg.XrayDirectBackendAddr(),
		contextLabel: fmt.Sprintf("%s:default", surface),
		route:        "unknown",
		routeSource:  "detect",
	}
	switch class {
	case detect.ClassHTTP:
		httpDecision := decideHTTPRoute(cfg, surface, initial, alpn, sni, allowDiagnostic)
		decision.target = httpDecision.Backend
		decision.contextLabel = httpDecision.Context
		decision.route = httpDecision.Route
		decision.host = httpDecision.Host
		decision.path = httpDecision.Path
		decision.reason = httpDecision.Text
		decision.status = httpDecision.Status
		decision.sendHTTP502 = true
	case detect.ClassPossibleHTTP:
		decision.status = 408
		decision.reason = "Request Timeout"
	case detect.ClassTimeout:
		decision.target = cfg.XrayDirectBackendAddr()
		decision.route = "xray-direct-timeout"
		decision.contextLabel = fmt.Sprintf("%s:xray-direct-timeout", surface)
	case detect.ClassVLESSRaw:
		decision.target = cfg.VLESSRawBackendAddr()
		decision.route = "vless-tcp"
		decision.contextLabel = fmt.Sprintf("%s:vless-tcp", surface)
	case detect.ClassTrojanRaw:
		decision.target = cfg.TrojanRawBackendAddr()
		decision.route = "trojan-tcp"
		decision.contextLabel = fmt.Sprintf("%s:trojan-tcp", surface)
	default:
		decision.route = "unknown"
		decision.contextLabel = fmt.Sprintf("%s:unknown", surface)
	}
	return decision
}

func resolveSNIRouteDecision(cfg runtime.Config, sni, surface string) (tlsRouteDecision, bool) {
	alias, ok := cfg.ResolveSNIRoute(sni)
	if !ok {
		return tlsRouteDecision{}, false
	}
	routeSuffix := strings.ReplaceAll(alias, "_", "-")
	decision := tlsRouteDecision{
		route:        "sni-" + routeSuffix,
		contextLabel: fmt.Sprintf("%s:sni-%s", surface, routeSuffix),
		routeSource:  "sni",
		matchedRoute: alias,
		reason:       "sni_match",
	}
	switch alias {
	case "http":
		decision.target = cfg.HTTPBackendAddr()
		decision.sendHTTP502 = true
	case "xray_direct":
		decision.target = cfg.XrayDirectBackendAddr()
	case "xray_tls":
		decision.target = cfg.XrayTLSBackendAddr()
	case "xray_ws":
		decision.target = cfg.XrayWSBackendAddr()
		decision.sendHTTP502 = true
	case "vless_tcp":
		decision.target = cfg.VLESSRawBackendAddr()
	case "trojan_tcp":
		decision.target = cfg.TrojanRawBackendAddr()
	default:
		return tlsRouteDecision{}, false
	}
	return decision, true
}

func resolveSNIPassthroughDecision(cfg runtime.Config, sni, surface string) (tlsRouteDecision, bool) {
	target, ok := cfg.ResolveSNIPassthrough(sni)
	if !ok {
		return tlsRouteDecision{}, false
	}
	return tlsRouteDecision{
		target:       target,
		contextLabel: fmt.Sprintf("%s:sni-passthrough", surface),
		route:        "sni-passthrough",
		routeSource:  "passthrough",
		reason:       "sni_passthrough",
	}, true
}

func admitConn(logger *log.Logger, guard *abuse.Guard, collector *observability.Collector, cfg runtime.Config, conn net.Conn, surface string) (func(), bool) {
	if guard == nil {
		return collector.TrackConnection(surface), true
	}
	ip, reason, release, err := guard.Acquire(cfg, conn.RemoteAddr(), surface)
	if err == nil {
		if release == nil {
			release = func() {}
		}
		trackRelease := collector.TrackConnection(surface)
		return func() {
			trackRelease()
			release()
		}, true
	}
	if errors.Is(err, abuse.ErrRejected) {
		if strings.TrimSpace(reason) == "" {
			reason = "abuse"
		}
		collector.ObserveReject(surface, reason)
		logger.Printf("edge-mux connection rejected surface=%s remote=%s ip=%s reason=%s", surface, safeRemote(conn), ip, reason)
		return nil, false
	}
	collector.ObserveReject(surface, "guard_error")
	logger.Printf("edge-mux connection guard failed surface=%s remote=%s ip=%s err=%v", surface, safeRemote(conn), ip, err)
	return nil, false
}

func backendLabel(cfg runtime.Config, target string) string {
	switch target {
	case cfg.HTTPBackendAddr():
		return "http"
	case cfg.XrayDirectBackendAddr():
		return "xray"
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
			return "passthrough"
		}
		return "other"
	}
}

func routeDecisionEvent(cfg runtime.Config, health *backendHealthState, class detect.InitialClass, target string, route, host, path, alpn, sni, reason string, httpStatus int, routeSource, matchedRoute string) observability.RouteDecisionEvent {
	healthKey := backendHealthKey(cfg, target)
	backendState := "unknown"
	if snapshot, ok := health.Lookup(healthKey); ok {
		backendState = backendStatus(snapshot, true)
	}
	return observability.RouteDecisionEvent{
		Surface:       "",
		DetectClass:   routeDetectClassName(class),
		RouteSource:   routeSource,
		Route:         route,
		MatchedRoute:  matchedRoute,
		Backend:       backendLabel(cfg, target),
		BackendAddr:   target,
		BackendStatus: backendState,
		Reason:        reason,
		HTTPStatus:    httpStatus,
		Host:          host,
		Path:          path,
		ALPN:          alpn,
		SNI:           sni,
	}
}

func routeDetectClassName(class detect.InitialClass) string {
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

func emitRouteDecision(logger *log.Logger, collector *observability.Collector, conn net.Conn, event observability.RouteDecisionEvent) {
	collector.ObserveRouteDecision(event)
	logRouteDecision(logger, conn, event)
}

type httpRouteDecision struct {
	Backend string
	Context string
	Route   string
	Host    string
	Path    string
	ALPN    string
	SNI     string
	Status  int
	Text    string
}

func decideHTTPRoute(cfg runtime.Config, surface string, initial []byte, alpn, sni string, allowDiagnostic bool) httpRouteDecision {
	decision := httpRouteDecision{
		Backend: cfg.HTTPBackendAddr(),
		Route:   "http-other",
		ALPN:    alpn,
		SNI:     sni,
	}
	if req, ok := routing.ParseHTTPRequest(initial); ok {
		decision.Route = routing.RouteLabel(req, alpn)
		decision.Host = req.Host
		decision.Path = req.Path
		if req.Path == "/diagnostic-probe" && !allowDiagnostic {
			decision.Route = "websocket-other"
			decision.Status = 401
			decision.Text = "Unauthorized"
		}
		if decision.Route == "websocket-other" {
			decision.Status = 401
			decision.Text = "Unauthorized"
		}
	} else if alpn == "h2" {
		decision.Route = "http2"
	}
	decision.Context = fmt.Sprintf("%s:http:%s", surface, decision.Route)
	return decision
}

func remoteIsLoopback(conn net.Conn) bool {
	if conn == nil || conn.RemoteAddr() == nil {
		return false
	}
	if addr, ok := conn.RemoteAddr().(*net.TCPAddr); ok && addr.IP != nil {
		return addr.IP.IsLoopback()
	}
	host, _, err := net.SplitHostPort(conn.RemoteAddr().String())
	if err != nil {
		return false
	}
	ip := net.ParseIP(strings.TrimSpace(host))
	return ip != nil && ip.IsLoopback()
}

func negotiatedALPN(conn net.Conn) string {
	if tlsConn, ok := conn.(*tls.Conn); ok {
		return tlsConn.ConnectionState().NegotiatedProtocol
	}
	return ""
}

func negotiatedSNI(conn net.Conn) string {
	if tlsConn, ok := conn.(*tls.Conn); ok {
		return tlsConn.ConnectionState().ServerName
	}
	return ""
}

func formatSNIRoutes(routes map[string]string) string {
	if len(routes) == 0 {
		return "-"
	}
	keys := make([]string, 0, len(routes))
	for host := range routes {
		keys = append(keys, host)
	}
	sort.Strings(keys)
	parts := make([]string, 0, len(keys))
	for _, host := range keys {
		parts = append(parts, host+"="+routes[host])
	}
	return strings.Join(parts, ",")
}

func formatSNIBackendMap(routes map[string]string) string {
	if len(routes) == 0 {
		return "-"
	}
	keys := make([]string, 0, len(routes))
	for host := range routes {
		keys = append(keys, host)
	}
	sort.Strings(keys)
	parts := make([]string, 0, len(keys))
	for _, host := range keys {
		parts = append(parts, host+"="+routes[host])
	}
	return strings.Join(parts, ",")
}

func xrayQuotaConfig(cfg runtime.Config) accounting.XrayQuotaConfig {
	return accounting.XrayQuotaConfig{
		StateRoot:        cfg.XrayQuotaRoot,
		RuntimeUnit:      cfg.XrayRuntimeUnit,
		EnforcerPath:     cfg.XrayQACEnforcer,
		SessionRoot:      cfg.XraySessionRoot,
		SessionHeartbeat: cfg.XraySessionHeartbeat,
	}
}

func safeRemote(conn net.Conn) string {
	if conn == nil || conn.RemoteAddr() == nil {
		return "-"
	}
	return conn.RemoteAddr().String()
}

func backendHealthSnapshot(cfg runtime.Config) map[string]observability.BackendHealthSnapshot {
	out := make(map[string]observability.BackendHealthSnapshot)
	checkBackend := func(addr string, enabled bool) observability.BackendHealthSnapshot {
		nowUnix := time.Now().Unix()
		if !enabled {
			return observability.BackendHealthSnapshot{
				Address:       addr,
				Healthy:       false,
				Status:        "disabled",
				Reason:        "disabled",
				CheckedAtUnix: nowUnix,
			}
		}
		dialer := net.Dialer{Timeout: 750 * time.Millisecond}
		started := time.Now()
		conn, err := dialer.Dial("tcp", addr)
		if err != nil {
			return observability.BackendHealthSnapshot{
				Address:       addr,
				Healthy:       false,
				Status:        "down",
				Reason:        err.Error(),
				CheckedAtUnix: nowUnix,
			}
		}
		latency := time.Since(started).Milliseconds()
		_ = conn.Close()
		status := "up"
		if latency >= 250 {
			status = "degraded"
		}
		return observability.BackendHealthSnapshot{
			Address:       addr,
			Healthy:       true,
			Status:        status,
			LatencyMS:     latency,
			CheckedAtUnix: nowUnix,
		}
	}
	addCheck := func(name, addr string, enabled bool) {
		if strings.TrimSpace(addr) == "" {
			return
		}
		out[name] = checkBackend(addr, enabled)
	}
	aggregateGroup := func(name string, members map[string]observability.BackendHealthSnapshot) {
		if len(members) == 0 {
			return
		}
		memberNames := make([]string, 0, len(members))
		for member := range members {
			memberNames = append(memberNames, member)
		}
		sort.Strings(memberNames)

		parts := make([]string, 0, len(memberNames))
		reasons := make([]string, 0, len(memberNames))
		var (
			allHealthy  = true
			hasDegraded bool
			maxLatency  int64
			checkedAt   int64
		)
		for _, member := range memberNames {
			snapshot := members[member]
			parts = append(parts, fmt.Sprintf("%s=%s", member, snapshot.Address))
			if snapshot.CheckedAtUnix > checkedAt {
				checkedAt = snapshot.CheckedAtUnix
			}
			if snapshot.LatencyMS > maxLatency {
				maxLatency = snapshot.LatencyMS
			}
			if snapshot.Status == "degraded" {
				hasDegraded = true
			}
			if snapshot.Healthy {
				continue
			}
			allHealthy = false
			reason := strings.TrimSpace(snapshot.Reason)
			if reason == "" {
				reason = snapshot.Status
			}
			reasons = append(reasons, fmt.Sprintf("%s:%s", member, reason))
		}

		status := "up"
		if hasDegraded {
			status = "degraded"
		}
		if !allHealthy {
			status = "degraded"
		}

		aggregate := observability.BackendHealthSnapshot{
			Address:       strings.Join(parts, ", "),
			Healthy:       allHealthy,
			Status:        status,
			CheckedAtUnix: checkedAt,
		}
		if maxLatency > 0 && allHealthy {
			aggregate.LatencyMS = maxLatency
		}
		if len(reasons) > 0 {
			aggregate.Reason = strings.Join(reasons, "; ")
		}
		out[name] = aggregate
	}

	addCheck("http", cfg.HTTPBackendAddr(), true)
	addCheck("xray-direct", cfg.XrayDirectBackendAddr(), true)
	addCheck("xray-tls", cfg.XrayTLSBackendAddr(), true)
	addCheck("xray-ws", cfg.XrayWSBackendAddr(), true)
	addCheck("fallback", cfg.XrayFallbackBackendAddr(), strings.TrimSpace(cfg.XrayFallbackBackendAddr()) != "")
	addCheck("vless", cfg.VLESSRawBackendAddr(), true)
	addCheck("trojan", cfg.TrojanRawBackendAddr(), true)
	for _, target := range uniquePassthroughTargets(cfg) {
		addCheck(passthroughBackendHealthKey(target), target, true)
	}
	aggregateGroup("xray", map[string]observability.BackendHealthSnapshot{
		"direct": out["xray-direct"],
		"tls":    out["xray-tls"],
		"ws":     out["xray-ws"],
	})
	return out
}

func uniquePassthroughTargets(cfg runtime.Config) []string {
	if len(cfg.SNIPassthrough) == 0 {
		return nil
	}
	seen := make(map[string]struct{}, len(cfg.SNIPassthrough))
	out := make([]string, 0, len(cfg.SNIPassthrough))
	for _, target := range cfg.SNIPassthrough {
		target = strings.TrimSpace(target)
		if target == "" {
			continue
		}
		if _, ok := seen[target]; ok {
			continue
		}
		seen[target] = struct{}{}
		out = append(out, target)
	}
	sort.Strings(out)
	return out
}

func writeHTTPError(conn net.Conn, status int, text string) error {
	body := fmt.Sprintf("%d %s\n", status, text)
	resp := fmt.Sprintf(
		"HTTP/1.1 %d %s\r\nConnection: close\r\nContent-Type: text/plain; charset=utf-8\r\nContent-Length: %d\r\n\r\n%s",
		status,
		text,
		len(body),
		body,
	)
	_, err := conn.Write([]byte(resp))
	return err
}
