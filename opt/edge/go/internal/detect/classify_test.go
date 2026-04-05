package detect

import (
	"crypto/tls"
	"io"
	"net"
	"strings"
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

func TestReadInitialWaitsForSplitVLESSRequest(t *testing.T) {
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

	payload := []byte{
		0x00,
		0x12, 0x34, 0x56, 0x78,
		0x9a, 0xbc,
		0x4d, 0xef,
		0x8a, 0xbc,
		0xde, 0xf0, 0x12, 0x34, 0x56, 0x78,
		0x00,
		0x01,
		0x01, 0xbb,
		0x02,
		0x0b,
		'e', 'x', 'a', 'm', 'p', 'l', 'e', '.', 'c', 'o', 'm',
	}

	if _, err := clientConn.Write(payload[:10]); err != nil {
		t.Fatalf("clientConn.Write first chunk failed: %v", err)
	}
	time.Sleep(20 * time.Millisecond)
	if _, err := clientConn.Write(payload[10:]); err != nil {
		t.Fatalf("clientConn.Write second chunk failed: %v", err)
	}

	select {
	case got := <-resultCh:
		if got.err != nil {
			t.Fatalf("ReadInitial err = %v", got.err)
		}
		if got.class != ClassVLESSRaw {
			t.Fatalf("ReadInitial class = %v, want ClassVLESSRaw", got.class)
		}
		if string(got.data) != string(payload) {
			t.Fatalf("ReadInitial payload mismatch")
		}
	case <-time.After(2 * time.Second):
		t.Fatal("ReadInitial timed out")
	}
}

func TestReadInitialWaitsForSplitTrojanRequest(t *testing.T) {
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

	payload := append([]byte(strings.Repeat("a", 56)), '\r', '\n', 0x01, 0x03, 0x0b)
	payload = append(payload, []byte("example.com")...)
	payload = append(payload, 0x01, 0xbb, '\r', '\n')

	if _, err := clientConn.Write(payload[:20]); err != nil {
		t.Fatalf("clientConn.Write first chunk failed: %v", err)
	}
	time.Sleep(20 * time.Millisecond)
	if _, err := clientConn.Write(payload[20:]); err != nil {
		t.Fatalf("clientConn.Write second chunk failed: %v", err)
	}

	select {
	case got := <-resultCh:
		if got.err != nil {
			t.Fatalf("ReadInitial err = %v", got.err)
		}
		if got.class != ClassTrojanRaw {
			t.Fatalf("ReadInitial class = %v, want ClassTrojanRaw", got.class)
		}
		if string(got.data) != string(payload) {
			t.Fatalf("ReadInitial payload mismatch")
		}
	case <-time.After(2 * time.Second):
		t.Fatal("ReadInitial timed out")
	}
}

func TestReadInitialTimeoutKeepsPartialVLESSOnRawRoute(t *testing.T) {
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
		data, class, err := ReadInitial(serverConn, 50*time.Millisecond, MaxPeekBytes)
		resultCh <- result{data: data, class: class, err: err}
	}()

	payload := []byte{
		0x00,
		0x12, 0x34, 0x56, 0x78,
		0x9a, 0xbc,
		0x4d, 0xef,
		0x8a, 0xbc,
	}
	if _, err := clientConn.Write(payload); err != nil {
		t.Fatalf("clientConn.Write failed: %v", err)
	}

	select {
	case got := <-resultCh:
		if got.err != nil {
			t.Fatalf("ReadInitial err = %v", got.err)
		}
		if got.class != ClassVLESSRaw {
			t.Fatalf("ReadInitial class = %v, want ClassVLESSRaw", got.class)
		}
		if string(got.data) != string(payload) {
			t.Fatalf("ReadInitial payload mismatch")
		}
	case <-time.After(2 * time.Second):
		t.Fatal("ReadInitial timed out")
	}
}

func TestReadInitialTimeoutKeepsPartialTrojanOnRawRoute(t *testing.T) {
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
		data, class, err := ReadInitial(serverConn, 50*time.Millisecond, MaxPeekBytes)
		resultCh <- result{data: data, class: class, err: err}
	}()

	payload := []byte(strings.Repeat("a", 20))
	if _, err := clientConn.Write(payload); err != nil {
		t.Fatalf("clientConn.Write failed: %v", err)
	}

	select {
	case got := <-resultCh:
		if got.err != nil {
			t.Fatalf("ReadInitial err = %v", got.err)
		}
		if got.class != ClassTrojanRaw {
			t.Fatalf("ReadInitial class = %v, want ClassTrojanRaw", got.class)
		}
		if string(got.data) != string(payload) {
			t.Fatalf("ReadInitial payload mismatch")
		}
	case <-time.After(2 * time.Second):
		t.Fatal("ReadInitial timed out")
	}
}
