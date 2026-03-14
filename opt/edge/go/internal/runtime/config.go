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
	defaultSSHTLSBackend       = "127.0.0.1:22443"
	defaultSSHWSBackend        = "127.0.0.1:10015"
	defaultVLESSRawBackend     = "127.0.0.1:28080"
	defaultTrojanRawBackend    = "127.0.0.1:28081"
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
	defaultCooldownRejects     = 8
	defaultCooldownWindow      = 30 * time.Second
	defaultCooldownDuration    = 120 * time.Second
	defaultRuntimeEnvFile      = "/etc/default/edge-runtime"
	defaultXrayInboundsFile    = "/usr/local/etc/xray/conf.d/10-inbounds.json"
	defaultAcceptProxyProtocol = false
	defaultTrustedProxyCIDRs   = "127.0.0.1/32,::1/128"
)

var validSNIRouteAliases = map[string]struct{}{
	"http":       {},
	"ssh_direct": {},
	"ssh_tls":    {},
	"ssh_ws":     {},
	"vless_tcp":  {},
	"trojan_tcp": {},
}

type Config struct {
	Provider            string
	PublicHTTPAddr      string
	PublicTLSAddr       string
	MetricsEnabled      bool
	MetricsListenAddr   string
	HTTPBackend         string
	SSHBackend          string
	SSHTLSBackend       string
	SSHWSBackend        string
	VLESSRawBackend     string
	TrojanRawBackend    string
	XrayInboundsFile    string
	VLESSRawSource      string
	TrojanRawSource     string
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
	CooldownRejects     int
	CooldownWindow      time.Duration
	CooldownDuration    time.Duration
	AcceptProxyProtocol bool
	TrustedProxyCIDRs   []string
	SNIRoutes           map[string]string
	SNIPassthrough      map[string]string
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
	cooldownWindow, err := envDurationSec(source, "EDGE_ABUSE_COOLDOWN_WINDOW_SEC", defaultCooldownWindow)
	if err != nil {
		return Config{}, err
	}
	cooldownDuration, err := envDurationSec(source, "EDGE_ABUSE_COOLDOWN_SEC", defaultCooldownDuration)
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
	cooldownRejects, err := envNonNegativeInt(source, "EDGE_ABUSE_COOLDOWN_TRIGGER_REJECTS", defaultCooldownRejects)
	if err != nil {
		return Config{}, err
	}
	acceptProxyProtocol, err := envBool(source, "EDGE_ACCEPT_PROXY_PROTOCOL", defaultAcceptProxyProtocol)
	if err != nil {
		return Config{}, err
	}
	metricsEnabled, err := envBool(source, "EDGE_METRICS_ENABLED", defaultMetricsEnabled)
	if err != nil {
		return Config{}, err
	}
	sniRoutes, err := envSNIRoutes(source, "EDGE_SNI_ROUTES")
	if err != nil {
		return Config{}, err
	}
	sniPassthrough, err := envSNIBackendMap(source, "EDGE_SNI_PASSTHROUGH")
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
		SSHTLSBackend:       normalizeAddr(envString(source, "EDGE_SSH_TLS_BACKEND", defaultSSHTLSBackend), "127.0.0.1"),
		SSHWSBackend:        normalizeAddr(envString(source, "EDGE_SSH_WS_BACKEND", defaultSSHWSBackend), "127.0.0.1"),
		VLESSRawBackend:     normalizeAddr(envString(source, "EDGE_XRAY_VLESS_RAW_BACKEND", defaultVLESSRawBackend), "127.0.0.1"),
		TrojanRawBackend:    normalizeAddr(envString(source, "EDGE_XRAY_TROJAN_RAW_BACKEND", defaultTrojanRawBackend), "127.0.0.1"),
		XrayInboundsFile:    strings.TrimSpace(envString(source, "EDGE_XRAY_INBOUNDS_FILE", defaultXrayInboundsFile)),
		VLESSRawSource:      "env:EDGE_XRAY_VLESS_RAW_BACKEND",
		TrojanRawSource:     "env:EDGE_XRAY_TROJAN_RAW_BACKEND",
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
		CooldownRejects:     cooldownRejects,
		CooldownWindow:      cooldownWindow,
		CooldownDuration:    cooldownDuration,
		AcceptProxyProtocol: acceptProxyProtocol,
		TrustedProxyCIDRs:   envCSV(source, "EDGE_TRUSTED_PROXY_CIDRS", defaultTrustedProxyCIDRs),
		SNIRoutes:           sniRoutes,
		SNIPassthrough:      sniPassthrough,
	}
	if refreshed, _, err := RefreshDiscoveredRawBackends(cfg); err == nil {
		cfg = refreshed
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
	if c.HTTPBackend == "" || c.SSHBackend == "" || c.SSHTLSBackend == "" || c.SSHWSBackend == "" || c.VLESSRawBackend == "" || c.TrojanRawBackend == "" {
		return errors.New("backend addresses must not be empty")
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
	if c.CooldownWindow <= 0 || c.CooldownDuration <= 0 {
		return errors.New("abuse cooldown windows must be > 0")
	}
	if c.MaxConnections < 0 || c.MaxConnectionsPerIP < 0 || c.AcceptRatePerIP < 0 {
		return errors.New("connection limits must be >= 0")
	}
	if c.CooldownRejects < 0 {
		return errors.New("abuse cooldown trigger must be >= 0")
	}
	for _, cidr := range c.TrustedProxyCIDRs {
		if _, err := parseCIDROrIP(cidr); err != nil {
			return fmt.Errorf("invalid trusted proxy CIDR %q: %w", cidr, err)
		}
	}
	for host, alias := range c.SNIRoutes {
		if _, err := normalizeSNIHost(host); err != nil {
			return fmt.Errorf("invalid EDGE_SNI_ROUTES host %q: %w", host, err)
		}
		if _, err := normalizeSNIRouteAlias(alias); err != nil {
			return fmt.Errorf("invalid EDGE_SNI_ROUTES alias %q for host %q: %w", alias, host, err)
		}
	}
	for host, target := range c.SNIPassthrough {
		if _, err := normalizeSNIHost(host); err != nil {
			return fmt.Errorf("invalid EDGE_SNI_PASSTHROUGH host %q: %w", host, err)
		}
		if strings.TrimSpace(target) == "" {
			return fmt.Errorf("invalid EDGE_SNI_PASSTHROUGH target for host %q: empty backend", host)
		}
		if _, _, err := net.SplitHostPort(target); err != nil {
			return fmt.Errorf("invalid EDGE_SNI_PASSTHROUGH target %q for host %q: %w", target, host, err)
		}
		if _, exists := c.SNIRoutes[host]; exists {
			return fmt.Errorf("host %q cannot exist in both EDGE_SNI_ROUTES and EDGE_SNI_PASSTHROUGH", host)
		}
	}
	return nil
}

func (c Config) HTTPListenAddr() string       { return c.PublicHTTPAddr }
func (c Config) TLSListenAddr() string        { return c.PublicTLSAddr }
func (c Config) MetricsAddr() string          { return c.MetricsListenAddr }
func (c Config) HTTPBackendAddr() string      { return c.HTTPBackend }
func (c Config) SSHBackendAddr() string       { return c.SSHBackend }
func (c Config) SSHTLSBackendAddr() string    { return c.SSHTLSBackend }
func (c Config) SSHWSBackendAddr() string     { return c.SSHWSBackend }
func (c Config) VLESSRawBackendAddr() string  { return c.VLESSRawBackend }
func (c Config) TrojanRawBackendAddr() string { return c.TrojanRawBackend }

func (c Config) Clone() Config {
	clone := c
	if len(c.TrustedProxyCIDRs) > 0 {
		clone.TrustedProxyCIDRs = append([]string(nil), c.TrustedProxyCIDRs...)
	}
	if len(c.SNIRoutes) > 0 {
		clone.SNIRoutes = make(map[string]string, len(c.SNIRoutes))
		for host, alias := range c.SNIRoutes {
			clone.SNIRoutes[host] = alias
		}
	}
	if len(c.SNIPassthrough) > 0 {
		clone.SNIPassthrough = make(map[string]string, len(c.SNIPassthrough))
		for host, target := range c.SNIPassthrough {
			clone.SNIPassthrough[host] = target
		}
	}
	return clone
}

func (c Config) ResolveSNIRoute(serverName string) (string, bool) {
	host, err := normalizeSNIHost(serverName)
	if err != nil {
		return "", false
	}
	alias, ok := c.SNIRoutes[host]
	if !ok {
		return "", false
	}
	return alias, true
}

func (c Config) ResolveSNIPassthrough(serverName string) (string, bool) {
	host, err := normalizeSNIHost(serverName)
	if err != nil {
		return "", false
	}
	target, ok := c.SNIPassthrough[host]
	if !ok {
		return "", false
	}
	return target, true
}

func (c Config) CloneSNIRoutes() map[string]string {
	if len(c.SNIRoutes) == 0 {
		return nil
	}
	out := make(map[string]string, len(c.SNIRoutes))
	for host, alias := range c.SNIRoutes {
		out[host] = alias
	}
	return out
}

func (c Config) CloneSNIPassthrough() map[string]string {
	if len(c.SNIPassthrough) == 0 {
		return nil
	}
	out := make(map[string]string, len(c.SNIPassthrough))
	for host, target := range c.SNIPassthrough {
		out[host] = target
	}
	return out
}

func (c Config) IsPassthroughBackend(target string) bool {
	for _, backend := range c.SNIPassthrough {
		if backend == target {
			return true
		}
	}
	return false
}

type envSource map[string]string

func loadEnvSource() envSource {
	processSource := make(envSource)
	for _, entry := range os.Environ() {
		key, value, ok := strings.Cut(entry, "=")
		if !ok {
			continue
		}
		processSource[key] = value
	}
	envFile := strings.TrimSpace(processSource["EDGE_RUNTIME_ENV_FILE"])
	if envFile == "" {
		envFile = defaultRuntimeEnvFile
	}
	fileSource := loadEnvFile(envFile)
	return mergeEnvSource(processSource, fileSource, envFile)
}

func mergeEnvSource(processSource envSource, fileSource map[string]string, envFile string) envSource {
	source := make(envSource, len(processSource)+len(fileSource)+1)
	for key, value := range processSource {
		source[key] = value
	}
	if len(fileSource) == 0 {
		if strings.TrimSpace(envFile) != "" {
			source["EDGE_RUNTIME_ENV_FILE"] = strings.TrimSpace(envFile)
		}
		return source
	}
	for key := range source {
		if strings.HasPrefix(key, "EDGE_") && key != "EDGE_RUNTIME_ENV_FILE" {
			delete(source, key)
		}
	}
	for key, value := range fileSource {
		source[key] = value
	}
	if strings.TrimSpace(envFile) != "" {
		source["EDGE_RUNTIME_ENV_FILE"] = strings.TrimSpace(envFile)
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

func envSNIRoutes(source envSource, key string) (map[string]string, error) {
	raw := strings.TrimSpace(source[key])
	return parseSNIRoutes(raw)
}

func envSNIBackendMap(source envSource, key string) (map[string]string, error) {
	raw := strings.TrimSpace(source[key])
	return parseSNIBackendMap(raw)
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

func parseSNIRoutes(raw string) (map[string]string, error) {
	text := strings.TrimSpace(raw)
	if text == "" {
		return nil, nil
	}
	parts := strings.FieldsFunc(text, func(r rune) bool {
		return r == ',' || r == '\n' || r == '\r'
	})
	out := make(map[string]string, len(parts))
	for _, part := range parts {
		entry := strings.TrimSpace(part)
		if entry == "" {
			continue
		}
		hostRaw, aliasRaw, ok := strings.Cut(entry, "=")
		if !ok {
			return nil, fmt.Errorf("invalid SNI route entry %q (expected host=route)", entry)
		}
		host, err := normalizeSNIHost(hostRaw)
		if err != nil {
			return nil, fmt.Errorf("invalid SNI host %q: %w", hostRaw, err)
		}
		alias, err := normalizeSNIRouteAlias(aliasRaw)
		if err != nil {
			return nil, fmt.Errorf("invalid SNI route alias %q: %w", aliasRaw, err)
		}
		if _, exists := out[host]; exists {
			return nil, fmt.Errorf("duplicate SNI host %q", host)
		}
		out[host] = alias
	}
	if len(out) == 0 {
		return nil, nil
	}
	return out, nil
}

func parseSNIBackendMap(raw string) (map[string]string, error) {
	text := strings.TrimSpace(raw)
	if text == "" {
		return nil, nil
	}
	parts := strings.FieldsFunc(text, func(r rune) bool {
		return r == ',' || r == '\n' || r == '\r'
	})
	out := make(map[string]string, len(parts))
	for _, part := range parts {
		entry := strings.TrimSpace(part)
		if entry == "" {
			continue
		}
		hostRaw, targetRaw, ok := strings.Cut(entry, "=")
		if !ok {
			return nil, fmt.Errorf("invalid SNI passthrough entry %q (expected host=backend)", entry)
		}
		host, err := normalizeSNIHost(hostRaw)
		if err != nil {
			return nil, fmt.Errorf("invalid SNI passthrough host %q: %w", hostRaw, err)
		}
		target := normalizeAddr(strings.TrimSpace(targetRaw), "127.0.0.1")
		if target == "" {
			return nil, fmt.Errorf("invalid SNI passthrough target %q", targetRaw)
		}
		if _, _, err := net.SplitHostPort(target); err != nil {
			return nil, fmt.Errorf("invalid SNI passthrough target %q: %w", targetRaw, err)
		}
		if _, exists := out[host]; exists {
			return nil, fmt.Errorf("duplicate SNI passthrough host %q", host)
		}
		out[host] = target
	}
	if len(out) == 0 {
		return nil, nil
	}
	return out, nil
}

func normalizeSNIRouteAlias(raw string) (string, error) {
	alias := strings.ToLower(strings.TrimSpace(raw))
	alias = strings.ReplaceAll(alias, "-", "_")
	if alias == "" {
		return "", errors.New("empty route alias")
	}
	if _, ok := validSNIRouteAliases[alias]; !ok {
		return "", fmt.Errorf("unsupported route alias %q", raw)
	}
	return alias, nil
}

func normalizeSNIHost(raw string) (string, error) {
	host := strings.ToLower(strings.TrimSpace(raw))
	host = strings.TrimSuffix(host, ".")
	if host == "" {
		return "", errors.New("empty host")
	}
	if strings.ContainsAny(host, "/:@") {
		return "", fmt.Errorf("host must not contain path, port, or userinfo")
	}
	labels := strings.Split(host, ".")
	for _, label := range labels {
		if label == "" {
			return "", fmt.Errorf("host has empty label")
		}
		if len(label) > 63 {
			return "", fmt.Errorf("label %q too long", label)
		}
		if strings.HasPrefix(label, "-") || strings.HasSuffix(label, "-") {
			return "", fmt.Errorf("label %q must not start or end with '-'", label)
		}
		for _, r := range label {
			if (r >= 'a' && r <= 'z') || (r >= '0' && r <= '9') || r == '-' {
				continue
			}
			return "", fmt.Errorf("label %q contains invalid character %q", label, r)
		}
	}
	return host, nil
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
