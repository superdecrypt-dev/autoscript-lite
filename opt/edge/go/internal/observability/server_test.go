package observability

import (
	"errors"
	"net"
	"net/http"
	"testing"

	edgeruntime "github.com/superdecrypt-dev/autoscript/opt/edge/go/internal/runtime"
)

func TestServerMarksMetricsInactiveOnUnexpectedServeError(t *testing.T) {
	server := &Server{}
	httpServer := &http.Server{}
	listener := &failingListener{err: errors.New("boom")}

	server.swap(httpServer, listener, "127.0.0.1:9910")
	server.serve(httpServer, listener, "127.0.0.1:9910")

	if server.Active() {
		t.Fatalf("Active() = true, want false after unexpected serve error")
	}
}

type failingListener struct {
	err    error
	closed bool
}

func (l *failingListener) Accept() (net.Conn, error) { return nil, l.err }
func (l *failingListener) Close() error {
	l.closed = true
	return nil
}
func (l *failingListener) Addr() net.Addr { return dummyAddr("127.0.0.1:9910") }

type dummyAddr string

func (a dummyAddr) Network() string { return "tcp" }
func (a dummyAddr) String() string  { return string(a) }

var _ net.Listener = (*failingListener)(nil)
var _ net.Addr = dummyAddr("")

func TestServerActiveFalseAfterClose(t *testing.T) {
	server := &Server{}
	httpServer := &http.Server{}
	listener := &failingListener{err: net.ErrClosed}

	server.swap(httpServer, listener, "127.0.0.1:9910")
	if !server.Active() {
		t.Fatalf("Active() = false, want true before close")
	}
	if err := server.Close(); err != nil {
		t.Fatalf("Close() error = %v", err)
	}
	if server.Active() {
		t.Fatalf("Active() = true, want false after close")
	}
}

func TestServerConfigureKeepsExistingMetricsListenerWhenAddrUnchanged(t *testing.T) {
	server := &Server{}
	listener, err := net.Listen("tcp", "127.0.0.1:0")
	if err != nil {
		t.Fatalf("listen error = %v", err)
	}
	defer func() {
		_ = server.Close()
	}()

	addr := listener.Addr().String()
	httpServer := &http.Server{}
	server.swap(httpServer, listener, addr)

	cfg := edgeruntime.Config{
		MetricsEnabled:    true,
		MetricsListenAddr: addr,
	}
	if err := server.Configure(cfg); err != nil {
		t.Fatalf("Configure() error = %v", err)
	}
	if got := server.Addr(); got != addr {
		t.Fatalf("Addr() = %q, want %q", got, addr)
	}
	if !server.Active() {
		t.Fatalf("Active() = false, want true")
	}
}

func TestServerConfigureClearsInactiveMetricsStateBeforeRebind(t *testing.T) {
	server := &Server{}
	listener, err := net.Listen("tcp", "127.0.0.1:0")
	if err != nil {
		t.Fatalf("listen error = %v", err)
	}
	addr := listener.Addr().String()
	_ = listener.Close()

	staleListener := &failingListener{err: net.ErrClosed}
	httpServer := &http.Server{}
	server.swap(httpServer, staleListener, addr)
	server.markInactive(httpServer, staleListener)
	defer func() {
		_ = server.Close()
	}()

	cfg := edgeruntime.Config{
		MetricsEnabled:    true,
		MetricsListenAddr: addr,
	}
	if err := server.Configure(cfg); err != nil {
		t.Fatalf("Configure() error = %v", err)
	}
	if !staleListener.closed {
		t.Fatalf("stale listener was not closed before rebind")
	}
	if !server.Active() {
		t.Fatalf("Active() = false, want true after rebind")
	}
}
