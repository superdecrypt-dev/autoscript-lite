package runtime

import (
	"errors"
	"fmt"
	"os"
	"strconv"
	"strings"
	"time"
)

const (
	defaultProvider       = "go"
	defaultPublicHTTPAddr = "0.0.0.0:80"
	defaultPublicTLSAddr  = "0.0.0.0:443"
	defaultHTTPBackend    = "127.0.0.1:18080"
	defaultSSHBackend     = "127.0.0.1:22022"
	defaultTLSCertFile    = "/opt/cert/fullchain.pem"
	defaultTLSKeyFile     = "/opt/cert/privkey.pem"
	defaultDetectTimeout  = 250 * time.Millisecond
	defaultTLSOn80        = true
)

type Config struct {
	Provider       string
	PublicHTTPAddr string
	PublicTLSAddr  string
	HTTPBackend    string
	SSHBackend     string
	TLSCertFile    string
	TLSKeyFile     string
	DetectTimeout  time.Duration
	ClassicTLSOn80 bool
}

func LoadConfig() (Config, error) {
	timeout, err := envDurationMS("EDGE_HTTP_DETECT_TIMEOUT_MS", defaultDetectTimeout)
	if err != nil {
		return Config{}, err
	}
	classicTLSOn80, err := envBool("EDGE_CLASSIC_TLS_ON_80", defaultTLSOn80)
	if err != nil {
		return Config{}, err
	}

	cfg := Config{
		Provider:       envString("EDGE_PROVIDER", defaultProvider),
		PublicHTTPAddr: normalizeAddr(envString("EDGE_PUBLIC_HTTP_PORT", defaultPublicHTTPAddr), "0.0.0.0"),
		PublicTLSAddr:  normalizeAddr(envString("EDGE_PUBLIC_TLS_PORT", defaultPublicTLSAddr), "0.0.0.0"),
		HTTPBackend:    normalizeAddr(envString("EDGE_NGINX_HTTP_BACKEND", defaultHTTPBackend), "127.0.0.1"),
		SSHBackend:     normalizeAddr(envString("EDGE_SSH_CLASSIC_BACKEND", defaultSSHBackend), "127.0.0.1"),
		TLSCertFile:    envString("EDGE_TLS_CERT_FILE", defaultTLSCertFile),
		TLSKeyFile:     envString("EDGE_TLS_KEY_FILE", defaultTLSKeyFile),
		DetectTimeout:  timeout,
		ClassicTLSOn80: classicTLSOn80,
	}
	return cfg, nil
}

func (c Config) Validate() error {
	if c.Provider != "" && c.Provider != "go" {
		return fmt.Errorf("unsupported EDGE_PROVIDER for edge-mux binary: %s", c.Provider)
	}
	if c.PublicHTTPAddr == "" || c.PublicTLSAddr == "" {
		return errors.New("listen addresses must not be empty")
	}
	if c.HTTPBackend == "" || c.SSHBackend == "" {
		return errors.New("backend addresses must not be empty")
	}
	if c.TLSCertFile == "" || c.TLSKeyFile == "" {
		return errors.New("TLS cert and key must not be empty")
	}
	if c.DetectTimeout <= 0 {
		return errors.New("detect timeout must be > 0")
	}
	return nil
}

func (c Config) HTTPListenAddr() string  { return c.PublicHTTPAddr }
func (c Config) TLSListenAddr() string   { return c.PublicTLSAddr }
func (c Config) HTTPBackendAddr() string { return c.HTTPBackend }
func (c Config) SSHBackendAddr() string  { return c.SSHBackend }

func envString(key, fallback string) string {
	v := strings.TrimSpace(os.Getenv(key))
	if v == "" {
		return fallback
	}
	return v
}

func envBool(key string, fallback bool) (bool, error) {
	v := strings.TrimSpace(os.Getenv(key))
	if v == "" {
		return fallback, nil
	}
	switch strings.ToLower(v) {
	case "1", "true", "yes", "on":
		return true, nil
	case "0", "false", "no", "off":
		return false, nil
	default:
		return false, fmt.Errorf("invalid boolean for %s", key)
	}
}

func envDurationMS(key string, fallback time.Duration) (time.Duration, error) {
	v := strings.TrimSpace(os.Getenv(key))
	if v == "" {
		return fallback, nil
	}
	n, err := strconv.Atoi(v)
	if err != nil || n <= 0 {
		return 0, fmt.Errorf("invalid integer milliseconds for %s", key)
	}
	return time.Duration(n) * time.Millisecond, nil
}

func normalizeAddr(raw, defaultHost string) string {
	raw = strings.TrimSpace(raw)
	if raw == "" {
		return ""
	}
	if strings.Contains(raw, ":") {
		return raw
	}
	return defaultHost + ":" + raw
}
