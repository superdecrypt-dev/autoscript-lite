package runtime

import (
	"bufio"
	"errors"
	"fmt"
	"net"
	"os"
	"strconv"
	"strings"
	"time"
)

const (
	defaultProvider            = "go"
	defaultPublicHTTPAddr      = "0.0.0.0:80"
	defaultPublicTLSAddr       = "0.0.0.0:443"
	defaultMetricsListenAddr   = "127.0.0.1:9910"
	defaultHTTPBackend         = "127.0.0.1:18080"
	defaultSSHBackend          = "127.0.0.1:22022"
	defaultTLSCertFile         = "/opt/cert/fullchain.pem"
	defaultTLSKeyFile          = "/opt/cert/privkey.pem"
	defaultDetectTimeout       = 250 * time.Millisecond
	defaultMetricsEnabled      = true
	defaultTLSOn80             = true
	defaultTLSHandshakeTimeout = 5 * time.Second
	defaultSSHQuotaRoot        = "/opt/quota/ssh"
	defaultSSHDropbearUnit     = "sshws-dropbear"
	defaultSSHQACEnforcer      = "/usr/local/bin/sshws-qac-enforcer"
	defaultSSHSessionRoot      = "/run/autoscript/sshws-sessions"
	defaultSSHSessionHeartbeat = 15 * time.Second
	defaultMaxConnections      = 4096
	defaultMaxConnectionsPerIP = 128
	defaultAcceptRatePerIP     = 60
	defaultAcceptRateWindow    = 10 * time.Second
	defaultRuntimeEnvFile      = "/etc/default/edge-runtime"
	defaultAcceptProxyProtocol = false
	defaultTrustedProxyCIDRs   = "127.0.0.1/32,::1/128"
	defaultOpenVPNBackend      = "127.0.0.1:21194"
	defaultOpenVPNTCPEnabled   = false
	defaultOpenVPNTLSEnabled   = false
)

type Config struct {
	Provider            string
	PublicHTTPAddr      string
	PublicTLSAddr       string
	MetricsEnabled      bool
	MetricsListenAddr   string
	HTTPBackend         string
	SSHBackend          string
	TLSCertFile         string
	TLSKeyFile          string
	DetectTimeout       time.Duration
	ClassicTLSOn80      bool
	TLSHandshakeTimeout time.Duration
	SSHQuotaRoot        string
	SSHDropbearUnit     string
	SSHQACEnforcer      string
	SSHSessionRoot      string
	SSHSessionHeartbeat time.Duration
	MaxConnections      int
	MaxConnectionsPerIP int
	AcceptRatePerIP     int
	AcceptRateWindow    time.Duration
	AcceptProxyProtocol bool
	TrustedProxyCIDRs   []string
	OVPNBackend         string
	OpenVPNTCPEnabled   bool
	OpenVPNTLSEnabled   bool
}

func LoadConfig() (Config, error) {
	source := loadEnvSource()

	timeout, err := envDurationMS(source, "EDGE_HTTP_DETECT_TIMEOUT_MS", defaultDetectTimeout)
	if err != nil {
		return Config{}, err
	}
	classicTLSOn80, err := envBool(source, "EDGE_CLASSIC_TLS_ON_80", defaultTLSOn80)
	if err != nil {
		return Config{}, err
	}
	handshakeTimeout, err := envDurationMS(source, "EDGE_TLS_HANDSHAKE_TIMEOUT_MS", defaultTLSHandshakeTimeout)
	if err != nil {
		return Config{}, err
	}
	sessionHeartbeat, err := envDurationSec(source, "EDGE_SSH_SESSION_HEARTBEAT_SEC", defaultSSHSessionHeartbeat)
	if err != nil {
		return Config{}, err
	}
	acceptRateWindow, err := envDurationSec(source, "EDGE_ACCEPT_RATE_WINDOW_SEC", defaultAcceptRateWindow)
	if err != nil {
		return Config{}, err
	}
	maxConnections, err := envNonNegativeInt(source, "EDGE_MAX_CONNS", defaultMaxConnections)
	if err != nil {
		return Config{}, err
	}
	maxConnectionsPerIP, err := envNonNegativeInt(source, "EDGE_MAX_CONNS_PER_IP", defaultMaxConnectionsPerIP)
	if err != nil {
		return Config{}, err
	}
	acceptRatePerIP, err := envNonNegativeInt(source, "EDGE_ACCEPT_RATE_LIMIT_PER_IP", defaultAcceptRatePerIP)
	if err != nil {
		return Config{}, err
	}
	acceptProxyProtocol, err := envBool(source, "EDGE_ACCEPT_PROXY_PROTOCOL", defaultAcceptProxyProtocol)
	if err != nil {
		return Config{}, err
	}
	openVPNTCPEnabled, err := envBool(source, "EDGE_OVPN_ENABLE_TCP", defaultOpenVPNTCPEnabled)
	if err != nil {
		return Config{}, err
	}
	openVPNTLSEnabled, err := envBool(source, "EDGE_OVPN_ENABLE_SSL", defaultOpenVPNTLSEnabled)
	if err != nil {
		return Config{}, err
	}
	metricsEnabled, err := envBool(source, "EDGE_METRICS_ENABLED", defaultMetricsEnabled)
	if err != nil {
		return Config{}, err
	}

	cfg := Config{
		Provider:            envString(source, "EDGE_PROVIDER", defaultProvider),
		PublicHTTPAddr:      normalizeAddr(envString(source, "EDGE_PUBLIC_HTTP_PORT", defaultPublicHTTPAddr), "0.0.0.0"),
		PublicTLSAddr:       normalizeAddr(envString(source, "EDGE_PUBLIC_TLS_PORT", defaultPublicTLSAddr), "0.0.0.0"),
		MetricsEnabled:      metricsEnabled,
		MetricsListenAddr:   normalizeAddr(envString(source, "EDGE_METRICS_LISTEN", defaultMetricsListenAddr), "127.0.0.1"),
		HTTPBackend:         normalizeAddr(envString(source, "EDGE_NGINX_HTTP_BACKEND", defaultHTTPBackend), "127.0.0.1"),
		SSHBackend:          normalizeAddr(envString(source, "EDGE_SSH_CLASSIC_BACKEND", defaultSSHBackend), "127.0.0.1"),
		TLSCertFile:         envString(source, "EDGE_TLS_CERT_FILE", defaultTLSCertFile),
		TLSKeyFile:          envString(source, "EDGE_TLS_KEY_FILE", defaultTLSKeyFile),
		DetectTimeout:       timeout,
		ClassicTLSOn80:      classicTLSOn80,
		TLSHandshakeTimeout: handshakeTimeout,
		SSHQuotaRoot:        envString(source, "EDGE_SSH_QUOTA_ROOT", defaultSSHQuotaRoot),
		SSHDropbearUnit:     envString(source, "EDGE_SSH_DROPBEAR_UNIT", defaultSSHDropbearUnit),
		SSHQACEnforcer:      envString(source, "EDGE_SSH_QAC_ENFORCER", defaultSSHQACEnforcer),
		SSHSessionRoot:      envString(source, "EDGE_SSH_SESSION_ROOT", defaultSSHSessionRoot),
		SSHSessionHeartbeat: sessionHeartbeat,
		MaxConnections:      maxConnections,
		MaxConnectionsPerIP: maxConnectionsPerIP,
		AcceptRatePerIP:     acceptRatePerIP,
		AcceptRateWindow:    acceptRateWindow,
		AcceptProxyProtocol: acceptProxyProtocol,
		TrustedProxyCIDRs:   envCSV(source, "EDGE_TRUSTED_PROXY_CIDRS", defaultTrustedProxyCIDRs),
		OVPNBackend:         normalizeAddr(envString(source, "EDGE_OVPN_TCP_BACKEND", defaultOpenVPNBackend), "127.0.0.1"),
		OpenVPNTCPEnabled:   openVPNTCPEnabled,
		OpenVPNTLSEnabled:   openVPNTLSEnabled,
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
	if c.MetricsEnabled {
		if c.MetricsListenAddr == "" {
			return errors.New("metrics listen address must not be empty when metrics are enabled")
		}
		if !isLoopbackListenAddr(c.MetricsListenAddr) {
			return errors.New("EDGE_METRICS_LISTEN must stay local-only (loopback)")
		}
	}
	if c.HTTPBackend == "" || c.SSHBackend == "" {
		return errors.New("backend addresses must not be empty")
	}
	if (c.OpenVPNTCPEnabled || c.OpenVPNTLSEnabled) && c.OVPNBackend == "" {
		return errors.New("OpenVPN backend address must not be empty when OpenVPN is enabled")
	}
	if c.TLSCertFile == "" || c.TLSKeyFile == "" {
		return errors.New("TLS cert and key must not be empty")
	}
	if c.DetectTimeout <= 0 {
		return errors.New("detect timeout must be > 0")
	}
	if c.TLSHandshakeTimeout <= 0 {
		return errors.New("TLS handshake timeout must be > 0")
	}
	if c.SSHSessionHeartbeat <= 0 {
		return errors.New("SSH session heartbeat must be > 0")
	}
	if c.AcceptRateWindow <= 0 {
		return errors.New("accept rate window must be > 0")
	}
	if c.MaxConnections < 0 || c.MaxConnectionsPerIP < 0 || c.AcceptRatePerIP < 0 {
		return errors.New("connection limits must be >= 0")
	}
	for _, cidr := range c.TrustedProxyCIDRs {
		if _, err := parseCIDROrIP(cidr); err != nil {
			return fmt.Errorf("invalid trusted proxy CIDR %q: %w", cidr, err)
		}
	}
	return nil
}

func (c Config) HTTPListenAddr() string  { return c.PublicHTTPAddr }
func (c Config) TLSListenAddr() string   { return c.PublicTLSAddr }
func (c Config) MetricsAddr() string     { return c.MetricsListenAddr }
func (c Config) HTTPBackendAddr() string { return c.HTTPBackend }
func (c Config) SSHBackendAddr() string  { return c.SSHBackend }
func (c Config) OVPNBackendAddr() string { return c.OVPNBackend }

type envSource map[string]string

func loadEnvSource() envSource {
	source := make(envSource)
	for _, entry := range os.Environ() {
		key, value, ok := strings.Cut(entry, "=")
		if !ok {
			continue
		}
		source[key] = value
	}
	envFile := strings.TrimSpace(source["EDGE_RUNTIME_ENV_FILE"])
	if envFile == "" {
		envFile = defaultRuntimeEnvFile
	}
	for key, value := range loadEnvFile(envFile) {
		source[key] = value
	}
	return source
}

func loadEnvFile(path string) map[string]string {
	file := strings.TrimSpace(path)
	if file == "" {
		return nil
	}
	fh, err := os.Open(file)
	if err != nil {
		return nil
	}
	defer fh.Close()

	out := make(map[string]string)
	scanner := bufio.NewScanner(fh)
	for scanner.Scan() {
		line := strings.TrimSpace(scanner.Text())
		if line == "" || strings.HasPrefix(line, "#") {
			continue
		}
		key, value, ok := strings.Cut(line, "=")
		if !ok {
			continue
		}
		key = strings.TrimSpace(key)
		if key == "" {
			continue
		}
		out[key] = strings.Trim(strings.TrimSpace(value), `"'`)
	}
	return out
}

func envString(source envSource, key, fallback string) string {
	v := strings.TrimSpace(source[key])
	if v == "" {
		return fallback
	}
	return v
}

func envCSV(source envSource, key, fallback string) []string {
	raw := strings.TrimSpace(source[key])
	if raw == "" {
		raw = fallback
	}
	if raw == "" {
		return nil
	}
	parts := strings.Split(raw, ",")
	out := make([]string, 0, len(parts))
	for _, part := range parts {
		text := strings.TrimSpace(part)
		if text != "" {
			out = append(out, text)
		}
	}
	return out
}

func envBool(source envSource, key string, fallback bool) (bool, error) {
	v := strings.TrimSpace(source[key])
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

func envDurationMS(source envSource, key string, fallback time.Duration) (time.Duration, error) {
	v := strings.TrimSpace(source[key])
	if v == "" {
		return fallback, nil
	}
	n, err := strconv.Atoi(v)
	if err != nil || n <= 0 {
		return 0, fmt.Errorf("invalid integer milliseconds for %s", key)
	}
	return time.Duration(n) * time.Millisecond, nil
}

func envDurationSec(source envSource, key string, fallback time.Duration) (time.Duration, error) {
	v := strings.TrimSpace(source[key])
	if v == "" {
		return fallback, nil
	}
	n, err := strconv.Atoi(v)
	if err != nil || n <= 0 {
		return 0, fmt.Errorf("invalid integer seconds for %s", key)
	}
	return time.Duration(n) * time.Second, nil
}

func envNonNegativeInt(source envSource, key string, fallback int) (int, error) {
	v := strings.TrimSpace(source[key])
	if v == "" {
		return fallback, nil
	}
	n, err := strconv.Atoi(v)
	if err != nil || n < 0 {
		return 0, fmt.Errorf("invalid non-negative integer for %s", key)
	}
	return n, nil
}

func parseCIDROrIP(raw string) (string, error) {
	text := strings.TrimSpace(raw)
	if text == "" {
		return "", errors.New("empty CIDR")
	}
	if strings.Contains(text, "/") {
		if _, _, err := net.ParseCIDR(text); err != nil {
			return "", err
		}
		return text, nil
	}
	ip := net.ParseIP(text)
	if ip == nil {
		return "", fmt.Errorf("invalid IP %q", text)
	}
	if ip.To4() != nil {
		return ip.String() + "/32", nil
	}
	return ip.String() + "/128", nil
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

func isLoopbackListenAddr(addr string) bool {
	host, _, err := net.SplitHostPort(strings.TrimSpace(addr))
	if err != nil {
		return false
	}
	host = strings.Trim(strings.TrimSpace(host), "[]")
	if host == "" {
		return false
	}
	if strings.EqualFold(host, "localhost") {
		return true
	}
	ip := net.ParseIP(host)
	return ip != nil && ip.IsLoopback()
}
