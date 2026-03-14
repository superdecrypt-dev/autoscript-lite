package detect

import (
	"crypto/tls"
	"io"
	"net"
	"testing"
	"time"
)

func captureClientHelloRecord(t *testing.T, serverName string) []byte {
	t.Helper()

	serverConn, clientConn := net.Pipe()
	defer serverConn.Close()
	defer clientConn.Close()

	recordCh := make(chan []byte, 1)
	errCh := make(chan error, 1)

	go func() {
		_ = serverConn.SetReadDeadline(time.Now().Add(2 * time.Second))
		header := make([]byte, 5)
		if _, err := io.ReadFull(serverConn, header); err != nil {
			errCh <- err
			return
		}
		recordLen := int(header[3])<<8 | int(header[4])
		body := make([]byte, recordLen)
		if _, err := io.ReadFull(serverConn, body); err != nil {
			errCh <- err
			return
		}
		recordCh <- append(header, body...)
	}()

	tlsConn := tls.Client(clientConn, &tls.Config{
		ServerName:         serverName,
		InsecureSkipVerify: true,
	})
	handshakeDone := make(chan error, 1)
	go func() {
		handshakeDone <- tlsConn.Handshake()
	}()

	var record []byte
	select {
	case record = <-recordCh:
	case err := <-errCh:
		t.Fatalf("captureClientHelloRecord read failed: %v", err)
	case <-time.After(2 * time.Second):
		t.Fatal("captureClientHelloRecord timed out")
	}

	_ = serverConn.Close()
	_ = clientConn.Close()
	<-handshakeDone
	return record
}

func TestExtractTLSServerName(t *testing.T) {
	record := captureClientHelloRecord(t, "VMESS.EXAMPLE.COM.")

	serverName, ok := ExtractTLSServerName(record)
	if !ok {
		t.Fatalf("ExtractTLSServerName ok = false, want true")
	}
	if serverName != "vmess.example.com" {
		t.Fatalf("ExtractTLSServerName = %q, want vmess.example.com", serverName)
	}
}

func TestExtractTLSServerNameRejectsTruncatedClientHello(t *testing.T) {
	record := captureClientHelloRecord(t, "vmess.example.com")
	record = record[:len(record)-1]

	if serverName, ok := ExtractTLSServerName(record); ok || serverName != "" {
		t.Fatalf("ExtractTLSServerName truncated = (%q, %t), want empty,false", serverName, ok)
	}
}

func TestReadInitialReturnsFullTLSClientHelloRecord(t *testing.T) {
	serverConn, clientConn := net.Pipe()
	defer serverConn.Close()
	defer clientConn.Close()

	type result struct {
		data  []byte
		class InitialClass
		err   error
	}
	resultCh := make(chan result, 1)
	go func() {
		data, class, err := ReadInitial(serverConn, 2*time.Second, MaxPeekBytes)
		resultCh <- result{data: data, class: class, err: err}
	}()

	tlsConn := tls.Client(clientConn, &tls.Config{
		ServerName:         "passthrough.example.com",
		InsecureSkipVerify: true,
	})
	handshakeDone := make(chan error, 1)
	go func() {
		handshakeDone <- tlsConn.Handshake()
	}()

	var got result
	select {
	case got = <-resultCh:
	case <-time.After(2 * time.Second):
		t.Fatal("ReadInitial timed out")
	}
	if got.err != nil {
		t.Fatalf("ReadInitial err = %v", got.err)
	}
	if got.class != ClassTLSClientHello {
		t.Fatalf("ReadInitial class = %v, want ClassTLSClientHello", got.class)
	}
	if _, ok := ExtractTLSServerName(got.data); !ok {
		t.Fatalf("ExtractTLSServerName on ReadInitial data = false, want true")
	}

	_ = serverConn.Close()
	_ = clientConn.Close()
	<-handshakeDone
}
