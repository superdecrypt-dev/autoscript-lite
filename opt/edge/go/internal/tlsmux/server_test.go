package tlsmux

import (
	"net"
	"testing"

	"github.com/superdecrypt-dev/autoscript/opt/edge/go/internal/runtime"
)

func TestServerListenRejectsMultiPortConfig(t *testing.T) {
	server := &Server{
		cfg: runtime.Config{
			PublicTLSAddrs: []string{"127.0.0.1:443", "127.0.0.1:8443"},
		},
	}

	if _, err := server.Listen(); err == nil {
		t.Fatalf("Listen() error = nil, want multi-port guard error")
	}
}

func TestServerListenAllBindsConfiguredTLSPorts(t *testing.T) {
	server := &Server{
		cfg: runtime.Config{
			PublicTLSAddrs: []string{reserveTLSAddr(t), reserveTLSAddr(t)},
		},
	}

	listeners, err := server.ListenAll()
	if err != nil {
		t.Fatalf("ListenAll() error = %v", err)
	}
	if len(listeners) != 2 {
		t.Fatalf("len(ListenAll()) = %d, want 2", len(listeners))
	}
	for _, ln := range listeners {
		_ = ln.Close()
	}
}

func reserveTLSAddr(t *testing.T) string {
	t.Helper()
	ln, err := net.Listen("tcp", "127.0.0.1:0")
	if err != nil {
		t.Fatalf("reserveTLSAddr listen error = %v", err)
	}
	addr := ln.Addr().String()
	if err := ln.Close(); err != nil {
		t.Fatalf("reserveTLSAddr close error = %v", err)
	}
	return addr
}
