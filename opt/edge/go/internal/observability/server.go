package observability

import (
	"context"
	"encoding/json"
	"errors"
	"log"
	"net"
	"net/http"
	"sync"
	"time"

	edgeruntime "github.com/superdecrypt-dev/autoscript/opt/edge/go/internal/runtime"
)

type Server struct {
	logger    *log.Logger
	collector *Collector
	configFn  func() edgeruntime.Config
	stateFn   func() ListenerSnapshot

	mu   sync.Mutex
	addr string
	ln   net.Listener
	srv  *http.Server
}

func NewServer(
	logger *log.Logger,
	collector *Collector,
	configFn func() edgeruntime.Config,
	stateFn func() ListenerSnapshot,
) *Server {
	return &Server{
		logger:    logger,
		collector: collector,
		configFn:  configFn,
		stateFn:   stateFn,
	}
}

func (s *Server) Configure(cfg edgeruntime.Config) error {
	if !cfg.MetricsEnabled {
		oldSrv, oldLn, oldAddr := s.swap(nil, nil, "")
		if oldSrv != nil && s.logger != nil {
			s.logger.Printf("edge-mux metrics listener disabled (was %s)", oldAddr)
		}
		return shutdownHTTPServer(oldSrv, oldLn)
	}

	handler := s.newHandler()
	listener, err := net.Listen("tcp", cfg.MetricsAddr())
	if err != nil {
		return err
	}
	server := &http.Server{
		Handler:           handler,
		ReadHeaderTimeout: 5 * time.Second,
	}

	oldSrv, oldLn, oldAddr := s.swap(server, listener, cfg.MetricsAddr())
	if err := shutdownHTTPServer(oldSrv, oldLn); err != nil && s.logger != nil {
		s.logger.Printf("edge-mux metrics shutdown failed addr=%s: %v", oldAddr, err)
	}

	if s.logger != nil && oldAddr != cfg.MetricsAddr() {
		s.logger.Printf("edge-mux metrics listener ready on %s", cfg.MetricsAddr())
	}
	go s.serve(server, listener, cfg.MetricsAddr())
	return nil
}

func (s *Server) Addr() string {
	s.mu.Lock()
	defer s.mu.Unlock()
	return s.addr
}

func (s *Server) Active() bool {
	s.mu.Lock()
	defer s.mu.Unlock()
	return s.srv != nil
}

func (s *Server) Close() error {
	oldSrv, oldLn, _ := s.swap(nil, nil, "")
	return shutdownHTTPServer(oldSrv, oldLn)
}

func (s *Server) serve(server *http.Server, listener net.Listener, addr string) {
	if err := server.Serve(listener); err != nil && !errors.Is(err, http.ErrServerClosed) && s.logger != nil {
		s.logger.Printf("edge-mux metrics server failed addr=%s: %v", addr, err)
	}
}

func (s *Server) swap(server *http.Server, listener net.Listener, addr string) (*http.Server, net.Listener, string) {
	s.mu.Lock()
	defer s.mu.Unlock()
	oldSrv := s.srv
	oldLn := s.ln
	oldAddr := s.addr
	s.srv = server
	s.ln = listener
	s.addr = addr
	return oldSrv, oldLn, oldAddr
}

func (s *Server) newHandler() http.Handler {
	mux := http.NewServeMux()
	mux.HandleFunc("/health", func(w http.ResponseWriter, r *http.Request) {
		if r.Method != http.MethodGet && r.Method != http.MethodHead {
			http.Error(w, "method not allowed", http.StatusMethodNotAllowed)
			return
		}
		w.Header().Set("Content-Type", "text/plain; charset=utf-8")
		_, _ = w.Write([]byte("ok\n"))
	})
	mux.HandleFunc("/status", func(w http.ResponseWriter, r *http.Request) {
		if r.Method != http.MethodGet && r.Method != http.MethodHead {
			http.Error(w, "method not allowed", http.StatusMethodNotAllowed)
			return
		}
		cfg := edgeruntime.Config{}
		if s.configFn != nil {
			cfg = s.configFn()
		}
		listeners := ListenerSnapshot{}
		if s.stateFn != nil {
			listeners = s.stateFn()
		}
		status := s.collector.Snapshot(cfg, listeners)
		w.Header().Set("Content-Type", "application/json; charset=utf-8")
		enc := json.NewEncoder(w)
		enc.SetIndent("", "  ")
		_ = enc.Encode(status)
	})
	mux.HandleFunc("/metrics", func(w http.ResponseWriter, r *http.Request) {
		if r.Method != http.MethodGet && r.Method != http.MethodHead {
			http.Error(w, "method not allowed", http.StatusMethodNotAllowed)
			return
		}
		cfg := edgeruntime.Config{}
		if s.configFn != nil {
			cfg = s.configFn()
		}
		listeners := ListenerSnapshot{}
		if s.stateFn != nil {
			listeners = s.stateFn()
		}
		w.Header().Set("Content-Type", "text/plain; version=0.0.4; charset=utf-8")
		_, _ = w.Write(s.collector.RenderPrometheus(cfg, listeners))
	})
	return mux
}

func shutdownHTTPServer(server *http.Server, listener net.Listener) error {
	if server == nil {
		if listener != nil {
			return listener.Close()
		}
		return nil
	}
	ctx, cancel := context.WithTimeout(context.Background(), 2*time.Second)
	defer cancel()
	err := server.Shutdown(ctx)
	if listener != nil {
		closeErr := listener.Close()
		if closeErr != nil && !errors.Is(closeErr, net.ErrClosed) && err == nil {
			err = closeErr
		}
	}
	return err
}
