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

func TestReadInitialDoesNotClassifyTruncatedTLSRecordAsClientHelloOnEOF(t *testing.T) {
	serverConn, clientConn := net.Pipe()
	defer serverConn.Close()
	defer clientConn.Close()

	resultCh := make(chan struct {
		data  []byte
		class InitialClass
		err   error
	}, 1)

	go func() {
		data, class, err := ReadInitial(serverConn, 2*time.Second, MaxPeekBytes)
		resultCh <- struct {
			data  []byte
			class InitialClass
			err   error
		}{data: data, class: class, err: err}
	}()

	// Looks like a TLS record header, but the body is missing/truncated.
	payload := []byte{0x16, 0x03, 0x03, 0x00, 0x20, 0x01, 0x00}
	if _, err := clientConn.Write(payload); err != nil {
		t.Fatalf("clientConn.Write failed: %v", err)
	}
	_ = clientConn.Close()

	select {
	case got := <-resultCh:
		if got.err != nil {
			t.Fatalf("ReadInitial err = %v, want nil", got.err)
		}
		if got.class != ClassTimeout {
			t.Fatalf("ReadInitial class = %v, want ClassTimeout for truncated TLS", got.class)
		}
		if string(got.data) != string(payload) {
			t.Fatalf("ReadInitial payload mismatch")
		}
	case <-time.After(2 * time.Second):
		t.Fatal("ReadInitial timed out")
	}
}

func TestIsOpenVPNClientHello(t *testing.T) {
	payload := []byte{
		0x00, 0x0e, 0x38, 0xe1, 0x07, 0x7d, 0x5b, 0xb3,
		0xe4, 0xe3, 0x48, 0x00, 0x00, 0x00, 0x00, 0x00,
	}
	if !IsOpenVPNClientHello(payload) {
		t.Fatal("IsOpenVPNClientHello = false, want true")
	}
}

func TestIsOpenVPNClientHelloRejectsShortOrInvalidPayload(t *testing.T) {
	cases := [][]byte{
		{0x00, 0x01},
		{0x00, 0x0e, 0x28, 0x00},
		{0x00, 0x10, 0x38, 0x00, 0x00},
	}
	for _, payload := range cases {
		if IsOpenVPNClientHello(payload) {
			t.Fatalf("IsOpenVPNClientHello(%x) = true, want false", payload)
		}
	}
}

func TestReadInitialDetectsOpenVPNClientHello(t *testing.T) {
	serverConn, clientConn := net.Pipe()
	defer serverConn.Close()
	defer clientConn.Close()

	resultCh := make(chan struct {
		data  []byte
		class InitialClass
		err   error
	}, 1)

	go func() {
		data, class, err := ReadInitial(serverConn, 2*time.Second, MaxPeekBytes)
		resultCh <- struct {
			data  []byte
			class InitialClass
			err   error
		}{data: data, class: class, err: err}
	}()

	payload := []byte{
		0x00, 0x0e, 0x38, 0xe1, 0x07, 0x7d, 0x5b, 0xb3,
		0xe4, 0xe3, 0x48, 0x00, 0x00, 0x00, 0x00, 0x00,
	}
	if _, err := clientConn.Write(payload); err != nil {
		t.Fatalf("clientConn.Write failed: %v", err)
	}

	select {
	case got := <-resultCh:
		if got.err != nil {
			t.Fatalf("ReadInitial err = %v", got.err)
		}
		if got.class != ClassOpenVPNRaw {
			t.Fatalf("ReadInitial class = %v, want ClassOpenVPNRaw", got.class)
		}
		if string(got.data) != string(payload) {
			t.Fatalf("ReadInitial payload mismatch")
		}
	case <-time.After(2 * time.Second):
		t.Fatal("ReadInitial timed out")
	}
}
