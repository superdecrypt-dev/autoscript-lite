package tlsmux

import (
	"crypto/tls"
	"crypto/x509"
	"fmt"
	"net"
	"time"

	"github.com/superdecrypt-dev/autoscript/opt/edge/go/internal/runtime"
)

type Diagnostics struct {
	CertificateSubject   string
	CertificateNotBefore time.Time
	CertificateNotAfter  time.Time
	AdvertisedALPN       []string
	MinVersion           string
}

type Server struct {
	cfg       runtime.Config
	tlsConfig *tls.Config
	diag      Diagnostics
}

func NewServer(cfg runtime.Config) (*Server, error) {
	cert, err := tls.LoadX509KeyPair(cfg.TLSCertFile, cfg.TLSKeyFile)
	if err != nil {
		return nil, err
	}
	leaf, err := leafCertificate(cert)
	if err != nil {
		return nil, err
	}
	alpn := []string{"h2", "http/1.1"}
	return &Server{
		cfg: cfg,
		tlsConfig: &tls.Config{
			MinVersion:   tls.VersionTLS12,
			Certificates: []tls.Certificate{cert},
			// Public TLS must advertise h2 so gRPC clients keep HTTP/2 all the way
			// through edge termination before nginx proxies the internal gRPC hop.
			NextProtos: alpn,
		},
		diag: Diagnostics{
			CertificateSubject:   leaf.Subject.String(),
			CertificateNotBefore: leaf.NotBefore.UTC(),
			CertificateNotAfter:  leaf.NotAfter.UTC(),
			AdvertisedALPN:       append([]string(nil), alpn...),
			MinVersion:           tlsVersionName(tls.VersionTLS12),
		},
	}, nil
}

func (s *Server) Listen() (net.Listener, error) {
	addrs := s.cfg.TLSListenAddrs()
	if len(addrs) != 1 {
		return nil, fmt.Errorf("tlsmux listen requires exactly one TLS listen address, got %d", len(addrs))
	}
	return net.Listen("tcp", addrs[0])
}

func (s *Server) ListenAll() ([]net.Listener, error) {
	addrs := s.cfg.TLSListenAddrs()
	if len(addrs) == 0 {
		return nil, fmt.Errorf("tlsmux listen requires at least one TLS listen address")
	}
	listeners := make([]net.Listener, 0, len(addrs))
	for _, addr := range addrs {
		ln, err := net.Listen("tcp", addr)
		if err != nil {
			for _, opened := range listeners {
				_ = opened.Close()
			}
			return nil, err
		}
		listeners = append(listeners, ln)
	}
	return listeners, nil
}

func (s *Server) AcceptTLSConn(conn net.Conn) (*tls.Conn, error) {
	tlsConn := tls.Server(conn, s.tlsConfig.Clone())
	if timeout := s.cfg.TLSHandshakeTimeout; timeout > 0 {
		_ = tlsConn.SetDeadline(time.Now().Add(timeout))
		defer tlsConn.SetDeadline(time.Time{})
	}
	if err := tlsConn.Handshake(); err != nil {
		_ = tlsConn.Close()
		return nil, err
	}
	return tlsConn, nil
}

func (s *Server) AcceptBufferedTLSConn(conn net.Conn, prefix []byte) (*tls.Conn, error) {
	return s.AcceptTLSConn(withPrefix(conn, prefix))
}

func (s *Server) Diagnostics() Diagnostics {
	if s == nil {
		return Diagnostics{}
	}
	out := s.diag
	out.AdvertisedALPN = append([]string(nil), out.AdvertisedALPN...)
	return out
}

func leafCertificate(cert tls.Certificate) (*x509.Certificate, error) {
	if cert.Leaf != nil {
		return cert.Leaf, nil
	}
	if len(cert.Certificate) == 0 {
		return nil, x509.ErrUnsupportedAlgorithm
	}
	return x509.ParseCertificate(cert.Certificate[0])
}

func tlsVersionName(version uint16) string {
	switch version {
	case tls.VersionTLS13:
		return "TLS1.3"
	case tls.VersionTLS12:
		return "TLS1.2"
	case tls.VersionTLS11:
		return "TLS1.1"
	case tls.VersionTLS10:
		return "TLS1.0"
	default:
		return "unknown"
	}
}
