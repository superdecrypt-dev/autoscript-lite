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
	httpListen  string
	tlsListen   string
	httpBackend string
	sshBackend  string
	certFile    string
	keyFile     string
	timeoutMs   int
}

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
		"edge-mux starting provider=%s http=%s tls=%s metrics=%s metrics_enabled=%t http_backend=%s ssh_direct_backend=%s ssh_tls_backend=%s ssh_ws_backend=%s vless_raw_backend=%s vless_source=%s trojan_raw_backend=%s trojan_source=%s timeout=%s tls_handshake_timeout=%s classic_tls_on_80=%t max_conns=%d max_conns_per_ip=%d accept_rate_per_ip=%d/%s cooldown=%d/%s/%s accept_proxy_protocol=%t",
		cfg.Provider,
		cfg.HTTPListenAddr(),
		cfg.TLSListenAddr(),
		cfg.MetricsAddr(),
		cfg.MetricsEnabled,
		cfg.HTTPBackendAddr(),
		cfg.SSHBackendAddr(),
		cfg.SSHTLSBackendAddr(),
		cfg.SSHWSBackendAddr(),
		cfg.VLESSRawBackendAddr(),
		cfg.VLESSRawSource,
		cfg.TrojanRawBackendAddr(),
		cfg.TrojanRawSource,
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

	httpListener, err := newReloadableListener(cfg.HTTPListenAddr())
	if err != nil {
		log.Fatalf("edge-mux http listen error: %v", err)
	}
	tlsListener, err := newReloadableListener(cfg.TLSListenAddr())
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

	logger.Printf("edge-mux http listener ready on %s", httpListener.Addr())
	logger.Printf("edge-mux tls listener ready on %s", tlsListener.Addr())

	guard := abuse.NewGuard()
	collector := observability.NewCollector(time.Now())
	backendHealth := newBackendHealthState(cfg)
	var metricsServer *observability.Server
	listenerState := func() observability.ListenerSnapshot {
		snapshot := observability.ListenerSnapshot{
			HTTPAddr: httpListener.Addr(),
			TLSAddr:  tlsListener.Addr(),
			HTTPUp:   httpListener.Addr() != "",
			TLSUp:    tlsListener.Addr() != "",
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
	errCh := make(chan error, 3)
	start := func(name string, fn func(context.Context) error) {
		wg.Add(1)
		go func() {
			defer wg.Done()
			if err := fn(ctx); err != nil && !errors.Is(err, context.Canceled) && !errors.Is(err, net.ErrClosed) {
				errCh <- errors.New(name + ": " + err.Error())
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
	flag.StringVar(&overrides.httpListen, "http-listen", "", "public HTTP listen address")
	flag.StringVar(&overrides.tlsListen, "tls-listen", "", "public TLS listen address")
	flag.StringVar(&overrides.httpBackend, "http-backend", "", "internal HTTP backend address")
	flag.StringVar(&overrides.sshBackend, "ssh-backend", "", "internal SSH classic backend address")
	flag.StringVar(&overrides.certFile, "cert-file", "", "TLS certificate file")
	flag.StringVar(&overrides.keyFile, "key-file", "", "TLS key file")
	flag.IntVar(&overrides.timeoutMs, "detect-timeout-ms", 0, "initial protocol detect timeout in milliseconds")
	flag.Parse()
	return overrides
}

func (o flagOverrides) Apply(cfg *runtime.Config) {
	if cfg == nil {
		return
	}
	if o.httpListen != "" {
		cfg.PublicHTTPAddr = o.httpListen
	}
	if o.tlsListen != "" {
		cfg.PublicTLSAddr = o.tlsListen
	}
	if o.httpBackend != "" {
		cfg.HTTPBackend = o.httpBackend
	}
	if o.sshBackend != "" {
		cfg.SSHBackend = o.sshBackend
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
	mu   sync.RWMutex
	ln   net.Listener
	addr string
}

func newReloadableListener(addr string) (*reloadableListener, error) {
	ln, err := net.Listen("tcp", addr)
	if err != nil {
		return nil, err
	}
	return &reloadableListener{ln: ln, addr: addr}, nil
}

func (l *reloadableListener) Addr() string {
	l.mu.RLock()
	defer l.mu.RUnlock()
	return l.addr
}

func (l *reloadableListener) current() net.Listener {
	l.mu.RLock()
	defer l.mu.RUnlock()
	return l.ln
}

func (l *reloadableListener) Accept(ctx context.Context) (net.Conn, error) {
	for {
		ln := l.current()
		if ln == nil {
			if ctx.Err() != nil {
				return nil, ctx.Err()
			}
			return nil, net.ErrClosed
		}
		conn, err := ln.Accept()
		if err == nil {
			return conn, nil
		}
		if ctx.Err() != nil {
			return nil, ctx.Err()
		}
		if ln != l.current() {
			continue
		}
		return nil, err
	}
}

func (l *reloadableListener) Swap(addr string) error {
	if addr == l.Addr() {
		return nil
	}
	newLn, err := net.Listen("tcp", addr)
	if err != nil {
		return err
	}
	l.mu.Lock()
	oldLn := l.ln
	l.ln = newLn
	l.addr = addr
	l.mu.Unlock()
	if oldLn != nil {
		_ = oldLn.Close()
	}
	return nil
}

func (l *reloadableListener) Close() error {
	l.mu.Lock()
	oldLn := l.ln
	l.ln = nil
	l.addr = ""
	l.mu.Unlock()
	if oldLn != nil {
		return oldLn.Close()
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
		if err := httpListener.Swap(newCfg.HTTPListenAddr()); err != nil {
			collector.ObserveReloadFailure("http_listener")
			logger.Printf("edge-mux reload http listener failed addr=%s: %v", newCfg.HTTPListenAddr(), err)
			_ = tlsLive.Reload(oldCfg)
			continue
		}
		if err := tlsListener.Swap(newCfg.TLSListenAddr()); err != nil {
			collector.ObserveReloadFailure("tls_listener")
			logger.Printf("edge-mux reload tls listener failed addr=%s: %v", newCfg.TLSListenAddr(), err)
			_ = httpListener.Swap(oldCfg.HTTPListenAddr())
			_ = tlsLive.Reload(oldCfg)
			continue
		}
		live.Set(newCfg)
		if backendHealth != nil {
			backendHealth.Refresh(newCfg)
		}
		if err := metricsServer.Configure(newCfg); err != nil {
			collector.ObserveReloadFailure("metrics")
			logger.Printf("edge-mux reload metrics reconfigure failed addr=%s: %v", newCfg.MetricsAddr(), err)
		}
		collector.ObserveReloadSuccess()
		logger.Printf(
			"edge-mux reloaded http=%s tls=%s metrics=%s metrics_enabled=%t http_backend=%s ssh_backend=%s vless_raw_backend=%s vless_source=%s trojan_raw_backend=%s trojan_source=%s timeout=%s tls_handshake_timeout=%s classic_tls_on_80=%t",
			newCfg.HTTPListenAddr(),
			newCfg.TLSListenAddr(),
			newCfg.MetricsAddr(),
			newCfg.MetricsEnabled,
			newCfg.HTTPBackendAddr(),
			newCfg.SSHBackendAddr(),
			newCfg.VLESSRawBackendAddr(),
			newCfg.VLESSRawSource,
			newCfg.TrojanRawBackendAddr(),
			newCfg.TrojanRawSource,
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

	var stats proxy.BridgeStats
	if target == cfg.SSHBackendAddr() {
		quotaCfg := sshQuotaConfig(cfg)
		if tcpAddr, ok := backend.LocalAddr().(*net.TCPAddr); ok {
			speedCtl := accounting.NewSSHSpeedController(logger, quotaCfg, tcpAddr.Port)
			speedCtl.Start()
			defer speedCtl.Stop()
			sessionTracker := accounting.NewSSHRuntimeSessionTracker(logger, quotaCfg, tcpAddr.Port, safeRemote(left), contextLabel, func() string {
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
			accounting.RecordSSHQuota(logger, quotaCfg, speedCtl.Username(), tcpAddr.Port, stats.LeftToRight+stats.RightToLeft)
			if err != nil {
				collector.ObserveBridgeError(contextLabel)
				logger.Printf("edge-mux bridge error target=%s context=%s: %v", target, contextLabel, err)
			}
			return
		}
	}

	var sessionTracker *accounting.SSHRuntimeSessionTracker
	if target == cfg.SSHBackendAddr() {
		quotaCfg := sshQuotaConfig(cfg)
		if tcpAddr, ok := backend.LocalAddr().(*net.TCPAddr); ok {
			sessionTracker = accounting.NewSSHRuntimeSessionTracker(logger, quotaCfg, tcpAddr.Port, safeRemote(left), contextLabel, nil)
			if sessionTracker != nil {
				sessionTracker.Start()
				defer sessionTracker.Stop()
			}
		}
	}

	stats, err = proxy.BridgeWithStats(left, backend, leftPrefix, nil)
	collector.ObserveBridgeBytes(contextLabel, stats.LeftToRight, stats.RightToLeft)
	if target == cfg.SSHBackendAddr() {
		quotaCfg := sshQuotaConfig(cfg)
		if tcpAddr, ok := backend.LocalAddr().(*net.TCPAddr); ok {
			accounting.RecordSSHQuotaByLocalPort(logger, quotaCfg, tcpAddr.Port, stats.LeftToRight+stats.RightToLeft)
		}
	}
	if err != nil {
		collector.ObserveBridgeError(contextLabel)
		logger.Printf("edge-mux bridge error target=%s context=%s: %v", target, contextLabel, err)
	}
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
		decision := decideHTTPRoute(cfg, "http-port", initial, "", "")
		event := routeDecisionEvent(cfg, health, class, decision.Backend, decision.Route, decision.Host, decision.Path, decision.ALPN, decision.SNI, "", decision.Status)
		event.Surface = "http-port"
		if decision.Status > 0 {
			emitRouteDecision(logger, collector, conn, event)
			_ = writeHTTPError(conn, decision.Status, decision.Text)
			return
		}
		if snapshot, blocked := routeBlockedByHealth(health, cfg, decision.Backend); blocked {
			event.BackendStatus = backendStatus(snapshot, true)
			event.Reason = "backend_unhealthy"
			event.HTTPStatus = 502
			emitRouteDecision(logger, collector, conn, event)
			_ = writeHTTPError(conn, 502, "Bad Gateway")
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
	case detect.ClassSSH:
		event := routeDecisionEvent(cfg, health, class, cfg.SSHBackendAddr(), "ssh-direct", "", "", "", "", "", 0)
		event.Surface = "http-port"
		if snapshot, blocked := routeBlockedByHealth(health, cfg, cfg.SSHBackendAddr()); blocked {
			event.BackendStatus = backendStatus(snapshot, true)
			event.Reason = "backend_unhealthy"
			emitRouteDecision(logger, collector, conn, event)
			return
		}
		emitRouteDecision(logger, collector, conn, event)
		bridgeToBackend(logger, cfg, collector, health, conn, cfg.SSHBackendAddr(), initial, "http-port:ssh-direct", false)
		return
	case detect.ClassTimeout:
		event := routeDecisionEvent(cfg, health, class, cfg.SSHBackendAddr(), "ssh-direct-timeout", "", "", "", "", "", 0)
		event.Surface = "http-port"
		if snapshot, blocked := routeBlockedByHealth(health, cfg, cfg.SSHBackendAddr()); blocked {
			event.BackendStatus = backendStatus(snapshot, true)
			event.Reason = "backend_unhealthy"
			emitRouteDecision(logger, collector, conn, event)
			return
		}
		emitRouteDecision(logger, collector, conn, event)
		bridgeToBackend(logger, cfg, collector, health, conn, cfg.SSHBackendAddr(), nil, "http-port:ssh-direct-timeout", false)
		return
	case detect.ClassPossibleHTTP:
		logger.Printf("edge-mux http port timed out with partial http request from %s", safeRemote(conn))
		_ = writeHTTPError(conn, 408, "Request Timeout")
		return
	default:
		event := routeDecisionEvent(cfg, health, class, cfg.SSHBackendAddr(), "ssh-direct-unknown", "", "", "", "", "", 0)
		event.Surface = "http-port"
		if snapshot, blocked := routeBlockedByHealth(health, cfg, cfg.SSHBackendAddr()); blocked {
			event.BackendStatus = backendStatus(snapshot, true)
			event.Reason = "backend_unhealthy"
			emitRouteDecision(logger, collector, conn, event)
			return
		}
		emitRouteDecision(logger, collector, conn, event)
		bridgeToBackend(logger, cfg, collector, health, conn, cfg.SSHBackendAddr(), initial, "http-port:ssh-direct-unknown", false)
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
		decision := decideHTTPRoute(cfg, "tls-port-plaintext", initial, "", "")
		event := routeDecisionEvent(cfg, health, class, decision.Backend, decision.Route, decision.Host, decision.Path, decision.ALPN, decision.SNI, "", decision.Status)
		event.Surface = "tls-port-plaintext"
		if decision.Status > 0 {
			emitRouteDecision(logger, collector, conn, event)
			_ = writeHTTPError(conn, decision.Status, decision.Text)
			return
		}
		if snapshot, blocked := routeBlockedByHealth(health, cfg, decision.Backend); blocked {
			event.BackendStatus = backendStatus(snapshot, true)
			event.Reason = "backend_unhealthy"
			event.HTTPStatus = 502
			emitRouteDecision(logger, collector, conn, event)
			_ = writeHTTPError(conn, 502, "Bad Gateway")
			return
		}
		emitRouteDecision(logger, collector, conn, event)
		bridgeToBackend(logger, cfg, collector, health, conn, decision.Backend, initial, decision.Context, true)
		return
	case detect.ClassPossibleHTTP:
		logger.Printf("edge-mux tls port timed out with partial plaintext http request from %s", safeRemote(conn))
		_ = writeHTTPError(conn, 408, "Request Timeout")
		return
	case detect.ClassSSH:
		event := routeDecisionEvent(cfg, health, class, cfg.SSHBackendAddr(), "ssh-direct", "", "", "", "", "", 0)
		event.Surface = "tls-port"
		if snapshot, blocked := routeBlockedByHealth(health, cfg, cfg.SSHBackendAddr()); blocked {
			event.BackendStatus = backendStatus(snapshot, true)
			event.Reason = "backend_unhealthy"
			emitRouteDecision(logger, collector, conn, event)
			return
		}
		emitRouteDecision(logger, collector, conn, event)
		bridgeToBackend(logger, cfg, collector, health, conn, cfg.SSHBackendAddr(), initial, "tls-port:ssh-direct", false)
		return
	case detect.ClassTimeout:
		event := routeDecisionEvent(cfg, health, class, cfg.SSHBackendAddr(), "ssh-direct-timeout", "", "", "", "", "", 0)
		event.Surface = "tls-port"
		if snapshot, blocked := routeBlockedByHealth(health, cfg, cfg.SSHBackendAddr()); blocked {
			event.BackendStatus = backendStatus(snapshot, true)
			event.Reason = "backend_unhealthy"
			emitRouteDecision(logger, collector, conn, event)
			return
		}
		emitRouteDecision(logger, collector, conn, event)
		bridgeToBackend(logger, cfg, collector, health, conn, cfg.SSHBackendAddr(), nil, "tls-port:ssh-direct-timeout", false)
		return
	default:
		event := routeDecisionEvent(cfg, health, class, cfg.SSHBackendAddr(), "ssh-direct-unknown", "", "", "", "", "", 0)
		event.Surface = "tls-port"
		if snapshot, blocked := routeBlockedByHealth(health, cfg, cfg.SSHBackendAddr()); blocked {
			event.BackendStatus = backendStatus(snapshot, true)
			event.Reason = "backend_unhealthy"
			emitRouteDecision(logger, collector, conn, event)
			return
		}
		emitRouteDecision(logger, collector, conn, event)
		bridgeToBackend(logger, cfg, collector, health, conn, cfg.SSHBackendAddr(), initial, "tls-port:ssh-direct-unknown", false)
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
	target := cfg.SSHBackendAddr()
	sendHTTP502 := false
	contextLabel := fmt.Sprintf("%s:default", surface)
	route := "unknown"
	host := ""
	path := ""
	httpStatus := 0
	reason := ""
	switch class {
	case detect.ClassHTTP:
		decision := decideHTTPRoute(cfg, surface, initial, alpn, sni)
		route = decision.Route
		host = decision.Host
		path = decision.Path
		httpStatus = decision.Status
		reason = decision.Text
		target = decision.Backend
		sendHTTP502 = true
		contextLabel = decision.Context
	case detect.ClassPossibleHTTP:
		logger.Printf("edge-mux tls request timed out with partial http request from %s", safeRemote(tlsConn))
		_ = writeHTTPError(tlsConn, 408, "Request Timeout")
		return
	case detect.ClassTimeout:
		target = cfg.SSHBackendAddr()
		route = "ssh-timeout"
		contextLabel = fmt.Sprintf("%s:ssh-timeout", surface)
	case detect.ClassSSH:
		target = cfg.SSHBackendAddr()
		route = "ssh"
		contextLabel = fmt.Sprintf("%s:ssh", surface)
	case detect.ClassVLESSRaw:
		target = cfg.VLESSRawBackendAddr()
		route = "vless-tcp"
		contextLabel = fmt.Sprintf("%s:vless-tcp", surface)
	case detect.ClassTrojanRaw:
		target = cfg.TrojanRawBackendAddr()
		route = "trojan-tcp"
		contextLabel = fmt.Sprintf("%s:trojan-tcp", surface)
	default:
		route = "unknown"
		contextLabel = fmt.Sprintf("%s:unknown", surface)
	}
	event := routeDecisionEvent(cfg, health, class, target, route, host, path, alpn, sni, reason, httpStatus)
	event.Surface = surface
	if httpStatus > 0 {
		emitRouteDecision(logger, collector, tlsConn, event)
		_ = writeHTTPError(tlsConn, httpStatus, reason)
		return
	}
	if snapshot, blocked := routeBlockedByHealth(health, cfg, target); blocked {
		event.BackendStatus = backendStatus(snapshot, true)
		if sendHTTP502 {
			event.HTTPStatus = 502
		}
		event.Reason = "backend_unhealthy"
		emitRouteDecision(logger, collector, tlsConn, event)
		if sendHTTP502 {
			_ = writeHTTPError(tlsConn, 502, "Bad Gateway")
		}
		return
	}
	emitRouteDecision(logger, collector, tlsConn, event)
	bridgeToBackend(logger, cfg, collector, health, tlsConn, target, initial, contextLabel, sendHTTP502)
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
	case cfg.SSHBackendAddr():
		return "ssh"
	case cfg.VLESSRawBackendAddr():
		return "vless"
	case cfg.TrojanRawBackendAddr():
		return "trojan"
	default:
		return "other"
	}
}

func routeDecisionEvent(cfg runtime.Config, health *backendHealthState, class detect.InitialClass, target string, route, host, path, alpn, sni, reason string, httpStatus int) observability.RouteDecisionEvent {
	healthKey := backendHealthKey(cfg, target)
	backendState := "unknown"
	if snapshot, ok := health.Lookup(healthKey); ok {
		backendState = backendStatus(snapshot, true)
	}
	return observability.RouteDecisionEvent{
		Surface:       "",
		DetectClass:   routeDetectClassName(class),
		Route:         route,
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
	case detect.ClassSSH:
		return "ssh"
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

func decideHTTPRoute(cfg runtime.Config, surface string, initial []byte, alpn, sni string) httpRouteDecision {
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

func sshQuotaConfig(cfg runtime.Config) accounting.SSHQuotaConfig {
	return accounting.SSHQuotaConfig{
		StateRoot:        cfg.SSHQuotaRoot,
		DropbearUnit:     cfg.SSHDropbearUnit,
		EnforcerPath:     cfg.SSHQACEnforcer,
		SessionRoot:      cfg.SSHSessionRoot,
		SessionHeartbeat: cfg.SSHSessionHeartbeat,
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
	addCheck("ssh-direct", cfg.SSHBackendAddr(), true)
	addCheck("ssh-tls", cfg.SSHTLSBackendAddr(), true)
	addCheck("ssh-ws", cfg.SSHWSBackendAddr(), true)
	addCheck("vless", cfg.VLESSRawBackendAddr(), true)
	addCheck("trojan", cfg.TrojanRawBackendAddr(), true)
	aggregateGroup("ssh", map[string]observability.BackendHealthSnapshot{
		"direct": out["ssh-direct"],
		"tls":    out["ssh-tls"],
		"ws":     out["ssh-ws"],
	})
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
