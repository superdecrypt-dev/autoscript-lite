package main

import (
	"context"
	"errors"
	"flag"
	"fmt"
	"log"
	"net"
	"os"
	"os/signal"
	"sync"
	"syscall"
	"time"

	"github.com/superdecrypt-dev/autoscript/opt/edge/go/internal/accounting"
	"github.com/superdecrypt-dev/autoscript/opt/edge/go/internal/detect"
	"github.com/superdecrypt-dev/autoscript/opt/edge/go/internal/proxy"
	"github.com/superdecrypt-dev/autoscript/opt/edge/go/internal/runtime"
	"github.com/superdecrypt-dev/autoscript/opt/edge/go/internal/tlsmux"
)

func main() {
	cfg, err := runtime.LoadConfig()
	if err != nil {
		log.Fatalf("edge-mux config error: %v", err)
	}

	overrideFromFlags(&cfg)

	if err := cfg.Validate(); err != nil {
		log.Fatalf("edge-mux validate error: %v", err)
	}

	logger := log.New(os.Stderr, "", log.LstdFlags)
	logger.Printf(
		"edge-mux starting provider=%s http=%s tls=%s http_backend=%s ssh_backend=%s timeout=%s classic_tls_on_80=%t",
		cfg.Provider,
		cfg.HTTPListenAddr(),
		cfg.TLSListenAddr(),
		cfg.HTTPBackendAddr(),
		cfg.SSHBackendAddr(),
		cfg.DetectTimeout,
		cfg.ClassicTLSOn80,
	)

	ctx, stop := signal.NotifyContext(context.Background(), syscall.SIGINT, syscall.SIGTERM)
	defer stop()

	var wg sync.WaitGroup
	errCh := make(chan error, 2)
	start := func(name string, fn func(context.Context) error) {
		wg.Add(1)
		go func() {
			defer wg.Done()
			if err := fn(ctx); err != nil && !errors.Is(err, context.Canceled) {
				errCh <- errors.New(name + ": " + err.Error())
			}
		}()
	}

	start("http-listener", func(ctx context.Context) error { return serveHTTPMux(ctx, logger, cfg) })
	start("tls-listener", func(ctx context.Context) error { return serveTLSMux(ctx, logger, cfg) })

	select {
	case <-ctx.Done():
		logger.Printf("edge-mux stopping: %v", ctx.Err())
	case err := <-errCh:
		stop()
		logger.Printf("edge-mux fatal: %v", err)
	}

	wg.Wait()
}

func overrideFromFlags(cfg *runtime.Config) {
	var (
		httpListen  = flag.String("http-listen", "", "public HTTP listen address")
		tlsListen   = flag.String("tls-listen", "", "public TLS listen address")
		httpBackend = flag.String("http-backend", "", "internal HTTP backend address")
		sshBackend  = flag.String("ssh-backend", "", "internal SSH classic backend address")
		certFile    = flag.String("cert-file", "", "TLS certificate file")
		keyFile     = flag.String("key-file", "", "TLS key file")
		timeoutMs   = flag.Int("detect-timeout-ms", 0, "initial protocol detect timeout in milliseconds")
	)
	flag.Parse()

	if *httpListen != "" {
		cfg.PublicHTTPAddr = *httpListen
	}
	if *tlsListen != "" {
		cfg.PublicTLSAddr = *tlsListen
	}
	if *httpBackend != "" {
		cfg.HTTPBackend = *httpBackend
	}
	if *sshBackend != "" {
		cfg.SSHBackend = *sshBackend
	}
	if *certFile != "" {
		cfg.TLSCertFile = *certFile
	}
	if *keyFile != "" {
		cfg.TLSKeyFile = *keyFile
	}
	if *timeoutMs > 0 {
		cfg.DetectTimeout = time.Duration(*timeoutMs) * time.Millisecond
	}
}

func serveHTTPMux(ctx context.Context, logger *log.Logger, cfg runtime.Config) error {
	var tlsServer *tlsmux.Server
	if cfg.ClassicTLSOn80 {
		var err error
		tlsServer, err = tlsmux.NewServer(cfg)
		if err != nil {
			return err
		}
	}

	ln, err := net.Listen("tcp", cfg.HTTPListenAddr())
	if err != nil {
		return err
	}
	defer ln.Close()

	go func() {
		<-ctx.Done()
		_ = ln.Close()
	}()

	logger.Printf("edge-mux http listener ready on %s", cfg.HTTPListenAddr())

	for {
		conn, err := ln.Accept()
		if err != nil {
			if ctx.Err() != nil {
				return nil
			}
			return err
		}
		go handleHTTPPortConn(logger, cfg, tlsServer, conn)
	}
}

func serveTLSMux(ctx context.Context, logger *log.Logger, cfg runtime.Config) error {
	server, err := tlsmux.NewServer(cfg)
	if err != nil {
		return err
	}

	ln, err := net.Listen("tcp", cfg.TLSListenAddr())
	if err != nil {
		return err
	}
	defer ln.Close()

	go func() {
		<-ctx.Done()
		_ = ln.Close()
	}()

	logger.Printf("edge-mux tls listener ready on %s", cfg.TLSListenAddr())

	for {
		conn, err := ln.Accept()
		if err != nil {
			if ctx.Err() != nil {
				return nil
			}
			return err
		}
		go handleTLSPortConn(logger, cfg, server, conn)
	}
}

func bridgeToBackend(logger *log.Logger, cfg runtime.Config, left net.Conn, target string, leftPrefix []byte, contextLabel string, sendHTTP502 bool) {
	backend, err := net.DialTimeout("tcp", target, 5*time.Second)
	if err != nil {
		logger.Printf("edge-mux backend dial failed target=%s context=%s: %v", target, contextLabel, err)
		if sendHTTP502 {
			_ = writeHTTPError(left, 502, "Bad Gateway")
		}
		return
	}
	defer backend.Close()

	var stats proxy.BridgeStats
	if target == cfg.SSHBackendAddr() {
		if tcpAddr, ok := backend.LocalAddr().(*net.TCPAddr); ok {
			speedCtl := accounting.NewSSHSpeedController(logger, accounting.SSHQuotaConfig{
				StateRoot:    cfg.SSHQuotaRoot,
				DropbearUnit: cfg.SSHDropbearUnit,
				EnforcerPath: cfg.SSHQACEnforcer,
			}, tcpAddr.Port)
			speedCtl.Start()
			defer speedCtl.Stop()
			stats, err = proxy.BridgeWithStatsAndOptions(left, backend, leftPrefix, nil, proxy.BridgeOptions{
				LeftToRight: speedCtl.UploadLimiter(),
				RightToLeft: speedCtl.DownloadLimiter(),
			})
			accounting.RecordSSHQuotaByLocalPort(logger, accounting.SSHQuotaConfig{
				StateRoot:    cfg.SSHQuotaRoot,
				DropbearUnit: cfg.SSHDropbearUnit,
				EnforcerPath: cfg.SSHQACEnforcer,
			}, tcpAddr.Port, stats.LeftToRight+stats.RightToLeft)
			if err != nil {
				logger.Printf("edge-mux bridge error target=%s context=%s: %v", target, contextLabel, err)
			}
			return
		}
	}
	stats, err = proxy.BridgeWithStats(left, backend, leftPrefix, nil)
	if target == cfg.SSHBackendAddr() {
		if tcpAddr, ok := backend.LocalAddr().(*net.TCPAddr); ok {
			accounting.RecordSSHQuotaByLocalPort(logger, accounting.SSHQuotaConfig{
				StateRoot:    cfg.SSHQuotaRoot,
				DropbearUnit: cfg.SSHDropbearUnit,
				EnforcerPath: cfg.SSHQACEnforcer,
			}, tcpAddr.Port, stats.LeftToRight+stats.RightToLeft)
		}
	}
	if err != nil {
		logger.Printf("edge-mux bridge error target=%s context=%s: %v", target, contextLabel, err)
	}
}

func handleHTTPPortConn(logger *log.Logger, cfg runtime.Config, tlsServer *tlsmux.Server, conn net.Conn) {
	defer conn.Close()

	initial, class, err := detect.ReadInitial(conn, cfg.DetectTimeout, detect.MaxPeekBytes)
	if err != nil {
		logger.Printf("edge-mux http read initial failed from %s: %v", safeRemote(conn), err)
		return
	}

	switch class {
	case detect.ClassHTTP:
		bridgeToBackend(logger, cfg, conn, cfg.HTTPBackendAddr(), initial, "http-port:http", true)
		return
	case detect.ClassTLSClientHello:
		if !cfg.ClassicTLSOn80 || tlsServer == nil {
			logger.Printf("edge-mux tls-on-80 disabled for %s", safeRemote(conn))
			return
		}
		tlsConn, err := tlsServer.AcceptBufferedTLSConn(conn, initial)
		if err != nil {
			logger.Printf("edge-mux tls-on-80 handshake failed: %v", err)
			return
		}
		defer tlsConn.Close()
		bridgeToBackend(logger, cfg, tlsConn, cfg.SSHBackendAddr(), nil, "http-port:ssh-ssl-tls", false)
		return
	case detect.ClassSSH:
		bridgeToBackend(logger, cfg, conn, cfg.SSHBackendAddr(), initial, "http-port:ssh-direct", false)
		return
	case detect.ClassTimeout:
		bridgeToBackend(logger, cfg, conn, cfg.SSHBackendAddr(), nil, "http-port:ssh-direct-timeout", false)
		return
	case detect.ClassPossibleHTTP:
		logger.Printf("edge-mux http port timed out with partial http request from %s", safeRemote(conn))
		_ = writeHTTPError(conn, 408, "Request Timeout")
		return
	default:
		bridgeToBackend(logger, cfg, conn, cfg.SSHBackendAddr(), initial, "http-port:ssh-direct-unknown", false)
	}
}

func handleTLSPortConn(logger *log.Logger, cfg runtime.Config, server *tlsmux.Server, conn net.Conn) {
	defer conn.Close()

	initial, class, err := detect.ReadInitial(conn, cfg.DetectTimeout, detect.MaxPeekBytes)
	if err != nil {
		logger.Printf("edge-mux public tls/raw read initial failed from %s: %v", safeRemote(conn), err)
		return
	}

	switch class {
	case detect.ClassTLSClientHello:
		tlsConn, err := server.AcceptBufferedTLSConn(conn, initial)
		if err != nil {
			logger.Printf("edge-mux tls handshake failed from %s: %v", safeRemote(conn), err)
			return
		}
		defer tlsConn.Close()
		handleTLSPayloadConn(logger, cfg, tlsConn)
		return
	case detect.ClassHTTP:
		bridgeToBackend(logger, cfg, conn, cfg.HTTPBackendAddr(), initial, "tls-port:http-plaintext", true)
		return
	case detect.ClassPossibleHTTP:
		logger.Printf("edge-mux tls port timed out with partial plaintext http request from %s", safeRemote(conn))
		_ = writeHTTPError(conn, 408, "Request Timeout")
		return
	case detect.ClassSSH:
		bridgeToBackend(logger, cfg, conn, cfg.SSHBackendAddr(), initial, "tls-port:ssh-direct", false)
		return
	case detect.ClassTimeout:
		bridgeToBackend(logger, cfg, conn, cfg.SSHBackendAddr(), nil, "tls-port:ssh-direct-timeout", false)
		return
	default:
		bridgeToBackend(logger, cfg, conn, cfg.SSHBackendAddr(), initial, "tls-port:ssh-direct-unknown", false)
		return
	}
}

func handleTLSPayloadConn(logger *log.Logger, cfg runtime.Config, tlsConn net.Conn) {
	initial, class, err := detect.ReadInitial(tlsConn, cfg.DetectTimeout, detect.MaxPeekBytes)
	if err != nil {
		logger.Printf("edge-mux tls read initial failed from %s: %v", safeRemote(tlsConn), err)
		return
	}
	target := cfg.SSHBackendAddr()
	sendHTTP502 := false
	switch class {
	case detect.ClassHTTP:
		target = cfg.HTTPBackendAddr()
		sendHTTP502 = true
	case detect.ClassPossibleHTTP:
		logger.Printf("edge-mux tls request timed out with partial http request from %s", safeRemote(tlsConn))
		_ = writeHTTPError(tlsConn, 408, "Request Timeout")
		return
	case detect.ClassTimeout:
		target = cfg.SSHBackendAddr()
	case detect.ClassSSH:
		target = cfg.SSHBackendAddr()
	}
	bridgeToBackend(logger, cfg, tlsConn, target, initial, "tls-port:tls-inner", sendHTTP502)
}

func safeRemote(conn net.Conn) string {
	if conn == nil || conn.RemoteAddr() == nil {
		return "-"
	}
	return conn.RemoteAddr().String()
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
