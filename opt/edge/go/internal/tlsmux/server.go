package tlsmux

import (
	"crypto/tls"
	"net"

	"github.com/superdecrypt-dev/autoscript/opt/edge/go/internal/runtime"
)

type Server struct {
	cfg       runtime.Config
	tlsConfig *tls.Config
}

func NewServer(cfg runtime.Config) (*Server, error) {
	cert, err := tls.LoadX509KeyPair(cfg.TLSCertFile, cfg.TLSKeyFile)
	if err != nil {
		return nil, err
	}
	return &Server{
		cfg: cfg,
		tlsConfig: &tls.Config{
			MinVersion:   tls.VersionTLS12,
			Certificates: []tls.Certificate{cert},
			NextProtos:   []string{"http/1.1"},
		},
	}, nil
}

func (s *Server) Listen() (net.Listener, error) {
	return net.Listen("tcp", s.cfg.TLSListenAddr())
}

func (s *Server) AcceptTLSConn(conn net.Conn) (*tls.Conn, error) {
	tlsConn := tls.Server(conn, s.tlsConfig.Clone())
	if err := tlsConn.Handshake(); err != nil {
		_ = tlsConn.Close()
		return nil, err
	}
	return tlsConn, nil
}

func (s *Server) AcceptBufferedTLSConn(conn net.Conn, prefix []byte) (*tls.Conn, error) {
	return s.AcceptTLSConn(withPrefix(conn, prefix))
}
