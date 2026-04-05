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
	defaultProvider             = "go"
	defaultPublicHTTPAddr       = "0.0.0.0:80"
	defaultPublicTLSAddr        = "0.0.0.0:443"
	defaultPublicHTTPPorts      = "80,8080,8880,2052,2082,2086,2095"
	defaultPublicTLSPorts       = "443,2053,2083,2087,2096,8443"
	defaultMetricsListenAddr    = "127.0.0.1:9910"
	defaultHTTPBackend          = "127.0.0.1:18080"
	defaultXrayDirectBackend    = "127.0.0.1:18080"
	defaultXrayTLSBackend       = "127.0.0.1:18443"
	defaultXrayWSBackend        = "127.0.0.1:18080"
	defaultXrayFallbackBackend  = "127.0.0.1:18443"
	defaultVLESSRawBackend      = "127.0.0.1:28080"
	defaultTrojanRawBackend     = "127.0.0.1:28081"
	defaultTLSCertFile          = "/opt/cert/fullchain.pem"
	defaultTLSKeyFile           = "/opt/cert/privkey.pem"
	defaultDetectTimeout        = 1500 * time.Millisecond
	defaultMetricsEnabled       = true
	defaultTLSOn80              = true
	defaultTLSHandshakeTimeout  = 5 * time.Second
	defaultXrayQuotaRoot        = "/opt/quota/xray"
	defaultXrayRuntimeUnit      = "xray"
	defaultXrayQACEnforcer      = "/usr/local/bin/true"
	defaultXrayManageBin        = "/usr/local/bin/manage"
	defaultXraySessionRoot      = "/run/autoscript/xray-edge-sessions"
	defaultXraySessionHeartbeat = 15 * time.Second
	defaultMaxConnections       = 4096
	defaultMaxConnectionsPerIP  = 128
	defaultAcceptRatePerIP      = 60
	defaultAcceptRateWindow     = 10 * time.Second
	defaultCooldownRejects      = 8
	defaultCooldownWindow       = 30 * time.Second
	defaultCooldownDuration     = 120 * time.Second
	defaultRuntimeEnvFile       = "/etc/default/edge-runtime"
	defaultXrayInboundsFile     = "/usr/local/etc/xray/conf.d/10-inbounds.json"
	defaultAcceptProxyProtocol  = false
	defaultTrustedProxyCIDRs    = "127.0.0.1/32,::1/128"
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
	Provider             string
	PublicHTTPAddr       string
	PublicTLSAddr        string
	PublicHTTPAddrs      []string
	PublicTLSAddrs       []string
	MetricsEnabled       bool
	MetricsListenAddr    string
	HTTPBackend          string
	XrayDirectBackend    string
	XrayTLSBackend       string
	XrayWSBackend        string
	XrayFallbackBackend  string
	VLESSRawBackend      string
	TrojanRawBackend     string
	XrayInboundsFile     string
	VLESSRawSource       string
	TrojanRawSource      string
	TLSCertFile          string
	TLSKeyFile           string
	DetectTimeout        time.Duration
	ClassicTLSOn80       bool
	TLSHandshakeTimeout  time.Duration
	XrayQuotaRoot        string
	XrayRuntimeUnit      string
	XrayQACEnforcer      string
	XrayManageBin        string
	XraySessionRoot      string
	XraySessionHeartbeat time.Duration
	MaxConnections       int
	MaxConnectionsPerIP  int
	AcceptRatePerIP      int
	AcceptRateWindow     time.Duration
	CooldownRejects      int
	CooldownWindow       time.Duration
	CooldownDuration     time.Duration
	AcceptProxyProtocol  bool
	TrustedProxyCIDRs    []string
	SNIRoutes            map[string]string
	SNIPassthrough       map[string]string
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
	sessionHeartbeat, err := envDurationSecAliases(source, defaultXraySessionHeartbeat, "EDGE_XRAY_SESSION_HEARTBEAT_SEC", "EDGE_SSH_SESSION_HEARTBEAT_SEC")
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
	publicHTTPAddrs, publicHTTPAddr, err := envListenAddrs(
		source,
		"EDGE_PUBLIC_HTTP_PORTS",
		"EDGE_PUBLIC_HTTP_PORT",
		defaultPublicHTTPPorts,
		defaultPublicHTTPAddr,
		"0.0.0.0",
	)
	if err != nil {
		return Config{}, err
	}
	publicTLSAddrs, publicTLSAddr, err := envListenAddrs(
		source,
		"EDGE_PUBLIC_TLS_PORTS",
		"EDGE_PUBLIC_TLS_PORT",
		defaultPublicTLSPorts,
		defaultPublicTLSAddr,
		"0.0.0.0",
	)
	if err != nil {
		return Config{}, err
	}

	cfg := Config{
		Provider:             envString(source, "EDGE_PROVIDER", defaultProvider),
		PublicHTTPAddr:       publicHTTPAddr,
		PublicTLSAddr:        publicTLSAddr,
		PublicHTTPAddrs:      publicHTTPAddrs,
		PublicTLSAddrs:       publicTLSAddrs,
		MetricsEnabled:       metricsEnabled,
		MetricsListenAddr:    normalizeAddr(envString(source, "EDGE_METRICS_LISTEN", defaultMetricsListenAddr), "127.0.0.1"),
		HTTPBackend:          normalizeAddr(envString(source, "EDGE_NGINX_HTTP_BACKEND", defaultHTTPBackend), "127.0.0.1"),
		XrayDirectBackend:    normalizeAddr(envStringAliases(source, defaultXrayDirectBackend, "EDGE_XRAY_DIRECT_BACKEND", "EDGE_SSH_CLASSIC_BACKEND"), "127.0.0.1"),
		XrayTLSBackend:       normalizeAddr(envStringAliases(source, defaultXrayTLSBackend, "EDGE_XRAY_TLS_BACKEND", "EDGE_SSH_TLS_BACKEND"), "127.0.0.1"),
		XrayWSBackend:        normalizeAddr(envStringAliases(source, defaultXrayWSBackend, "EDGE_XRAY_WS_BACKEND", "EDGE_SSH_WS_BACKEND"), "127.0.0.1"),
		XrayFallbackBackend:  normalizeAddr(envStringAliases(source, defaultXrayFallbackBackend, "EDGE_XRAY_FALLBACK_BACKEND", "EDGE_OPENVPN_TCP_BACKEND"), "127.0.0.1"),
		VLESSRawBackend:      normalizeAddr(envString(source, "EDGE_XRAY_VLESS_RAW_BACKEND", defaultVLESSRawBackend), "127.0.0.1"),
		TrojanRawBackend:     normalizeAddr(envString(source, "EDGE_XRAY_TROJAN_RAW_BACKEND", defaultTrojanRawBackend), "127.0.0.1"),
		XrayInboundsFile:     strings.TrimSpace(envString(source, "EDGE_XRAY_INBOUNDS_FILE", defaultXrayInboundsFile)),
		VLESSRawSource:       "env:EDGE_XRAY_VLESS_RAW_BACKEND",
		TrojanRawSource:      "env:EDGE_XRAY_TROJAN_RAW_BACKEND",
		TLSCertFile:          envString(source, "EDGE_TLS_CERT_FILE", defaultTLSCertFile),
		TLSKeyFile:           envString(source, "EDGE_TLS_KEY_FILE", defaultTLSKeyFile),
		DetectTimeout:        timeout,
		ClassicTLSOn80:       classicTLSOn80,
		TLSHandshakeTimeout:  handshakeTimeout,
		XrayQuotaRoot:        envStringAliases(source, defaultXrayQuotaRoot, "EDGE_XRAY_QUOTA_ROOT", "EDGE_SSH_QUOTA_ROOT"),
		XrayRuntimeUnit:      envStringAliases(source, defaultXrayRuntimeUnit, "EDGE_XRAY_RUNTIME_UNIT", "EDGE_SSH_DROPBEAR_UNIT"),
		XrayQACEnforcer:      envStringAliases(source, defaultXrayQACEnforcer, "EDGE_XRAY_QAC_ENFORCER", "EDGE_SSH_QAC_ENFORCER"),
		XrayManageBin:        envStringAliases(source, defaultXrayManageBin, "EDGE_XRAY_MANAGE_BIN", "EDGE_SSH_MANAGE_BIN"),
		XraySessionRoot:      envStringAliases(source, defaultXraySessionRoot, "EDGE_XRAY_SESSION_ROOT", "EDGE_SSH_SESSION_ROOT"),
		XraySessionHeartbeat: sessionHeartbeat,
		MaxConnections:       maxConnections,
		MaxConnectionsPerIP:  maxConnectionsPerIP,
		AcceptRatePerIP:      acceptRatePerIP,
		AcceptRateWindow:     acceptRateWindow,
		CooldownRejects:      cooldownRejects,
		CooldownWindow:       cooldownWindow,
		CooldownDuration:     cooldownDuration,
		AcceptProxyProtocol:  acceptProxyProtocol,
		TrustedProxyCIDRs:    envCSV(source, "EDGE_TRUSTED_PROXY_CIDRS", defaultTrustedProxyCIDRs),
		SNIRoutes:            sniRoutes,
		SNIPassthrough:       sniPassthrough,
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
	httpListenAddrs := c.HTTPListenAddrs()
	tlsListenAddrs := c.TLSListenAddrs()
	if len(httpListenAddrs) == 0 || len(tlsListenAddrs) == 0 {
		return errors.New("listen addresses must not be empty")
	}
	if err := validateListenAddrs(httpListenAddrs, "HTTP"); err != nil {
		return err
	}
	if err := validateListenAddrs(tlsListenAddrs, "TLS"); err != nil {
		return err
	}
	if c.MetricsEnabled {
		if c.MetricsListenAddr == "" {
			return errors.New("metrics listen address must not be empty when metrics are enabled")
		}
		if !isLoopbackListenAddr(c.MetricsListenAddr) {
			return errors.New("EDGE_METRICS_LISTEN must stay local-only (loopback)")
		}
	}
	if c.HTTPBackend == "" || c.XrayDirectBackend == "" || c.XrayTLSBackend == "" || c.XrayWSBackend == "" || c.VLESSRawBackend == "" || c.TrojanRawBackend == "" {
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
	if c.XraySessionHeartbeat <= 0 {
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
		if targetLoopsToAnyPublicListener(target, httpListenAddrs) {
			return fmt.Errorf(
				"invalid EDGE_SNI_PASSTHROUGH target %q for host %q: target loops to edge public HTTP listener set %q",
				target,
				host,
				strings.Join(httpListenAddrs, ","),
			)
		}
		if targetLoopsToAnyPublicListener(target, tlsListenAddrs) {
			return fmt.Errorf(
				"invalid EDGE_SNI_PASSTHROUGH target %q for host %q: target loops to edge public TLS listener set %q",
				target,
				host,
				strings.Join(tlsListenAddrs, ","),
			)
		}
		if _, exists := c.SNIRoutes[host]; exists {
			return fmt.Errorf("host %q cannot exist in both EDGE_SNI_ROUTES and EDGE_SNI_PASSTHROUGH", host)
		}
	}
	return nil
}

func (c Config) HTTPListenAddr() string {
	if len(c.PublicHTTPAddrs) > 0 {
		return c.PublicHTTPAddrs[0]
	}
	return c.PublicHTTPAddr
}

func (c Config) TLSListenAddr() string {
	if len(c.PublicTLSAddrs) > 0 {
		return c.PublicTLSAddrs[0]
	}
	return c.PublicTLSAddr
}

func (c Config) HTTPListenAddrs() []string {
	if len(c.PublicHTTPAddrs) > 0 {
		return append([]string(nil), c.PublicHTTPAddrs...)
	}
	if c.PublicHTTPAddr == "" {
		return nil
	}
	return []string{c.PublicHTTPAddr}
}

func (c Config) TLSListenAddrs() []string {
	if len(c.PublicTLSAddrs) > 0 {
		return append([]string(nil), c.PublicTLSAddrs...)
	}
	if c.PublicTLSAddr == "" {
		return nil
	}
	return []string{c.PublicTLSAddr}
}

func (c Config) MetricsAddr() string             { return c.MetricsListenAddr }
func (c Config) HTTPBackendAddr() string         { return c.HTTPBackend }
func (c Config) XrayDirectBackendAddr() string   { return c.XrayDirectBackend }
func (c Config) XrayTLSBackendAddr() string      { return c.XrayTLSBackend }
func (c Config) XrayWSBackendAddr() string       { return c.XrayWSBackend }
func (c Config) XrayFallbackBackendAddr() string { return c.XrayFallbackBackend }
func (c Config) VLESSRawBackendAddr() string     { return c.VLESSRawBackend }
func (c Config) TrojanRawBackendAddr() string    { return c.TrojanRawBackend }

func (c Config) Clone() Config {
	clone := c
	if len(c.PublicHTTPAddrs) > 0 {
		clone.PublicHTTPAddrs = append([]string(nil), c.PublicHTTPAddrs...)
	}
	if len(c.PublicTLSAddrs) > 0 {
		clone.PublicTLSAddrs = append([]string(nil), c.PublicTLSAddrs...)
	}
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

func envStringAliases(source envSource, fallback string, keys ...string) string {
	for _, key := range keys {
		if v := strings.TrimSpace(source[key]); v != "" {
			return v
		}
	}
	return fallback
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

func envListenAddrs(source envSource, listKey, singleKey, defaultList, defaultSingle, defaultHost string) ([]string, string, error) {
	listRaw := strings.TrimSpace(source[listKey])
	singleRaw := strings.TrimSpace(source[singleKey])
	switch {
	case listRaw != "":
		addrs, err := parseListenAddrs(listRaw, defaultHost)
		if err != nil {
			return nil, "", fmt.Errorf("invalid %s: %w", listKey, err)
		}
		primary := addrs[0]
		if singleRaw != "" {
			primary = normalizeAddr(singleRaw, defaultHost)
			if _, _, err := net.SplitHostPort(primary); err != nil {
				return nil, "", fmt.Errorf("invalid %s: %w", singleKey, err)
			}
			addrs = prioritizeListenAddr(addrs, primary)
		}
		return addrs, primary, nil
	case singleRaw != "":
		addr := normalizeAddr(singleRaw, defaultHost)
		if _, _, err := net.SplitHostPort(addr); err != nil {
			return nil, "", fmt.Errorf("invalid %s: %w", singleKey, err)
		}
		return []string{addr}, addr, nil
	default:
		addrs, err := parseListenAddrs(defaultList, defaultHost)
		if err != nil {
			return nil, "", err
		}
		return addrs, normalizeAddr(defaultSingle, defaultHost), nil
	}
}

func prioritizeListenAddr(addrs []string, primary string) []string {
	primary = strings.TrimSpace(primary)
	if primary == "" {
		return append([]string(nil), addrs...)
	}
	out := make([]string, 0, len(addrs)+1)
	out = append(out, primary)
	for _, addr := range addrs {
		if strings.TrimSpace(addr) == primary {
			continue
		}
		out = append(out, addr)
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

func envDurationSecAliases(source envSource, fallback time.Duration, keys ...string) (time.Duration, error) {
	for _, key := range keys {
		v := strings.TrimSpace(source[key])
		if v == "" {
			continue
		}
		n, err := strconv.Atoi(v)
		if err != nil || n <= 0 {
			return 0, fmt.Errorf("invalid integer seconds for %s", key)
		}
		return time.Duration(n) * time.Second, nil
	}
	return fallback, nil
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

func parseListenAddrs(raw, defaultHost string) ([]string, error) {
	parts := strings.FieldsFunc(strings.TrimSpace(raw), func(r rune) bool {
		return r == ',' || r == '\n' || r == '\r' || r == '\t' || r == ' '
	})
	out := make([]string, 0, len(parts))
	seen := make(map[string]struct{}, len(parts))
	for _, part := range parts {
		addr := normalizeAddr(part, defaultHost)
		if addr == "" {
			continue
		}
		if _, _, err := net.SplitHostPort(addr); err != nil {
			return nil, err
		}
		if _, ok := seen[addr]; ok {
			continue
		}
		seen[addr] = struct{}{}
		out = append(out, addr)
	}
	if len(out) == 0 {
		return nil, errors.New("empty listen address list")
	}
	return out, nil
}

func validateListenAddrs(addrs []string, label string) error {
	if len(addrs) == 0 {
		return fmt.Errorf("%s listen addresses must not be empty", label)
	}
	seen := make(map[string]struct{}, len(addrs))
	for _, addr := range addrs {
		if strings.TrimSpace(addr) == "" {
			return fmt.Errorf("%s listen address must not be empty", label)
		}
		if _, _, err := net.SplitHostPort(addr); err != nil {
			return fmt.Errorf("invalid %s listen address %q: %w", label, addr, err)
		}
		if _, ok := seen[addr]; ok {
			return fmt.Errorf("duplicate %s listen address %q", label, addr)
		}
		seen[addr] = struct{}{}
	}
	return nil
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

func targetLoopsToPublicListener(target, listen string) bool {
	targetHost, targetPort, err := net.SplitHostPort(strings.TrimSpace(target))
	if err != nil {
		return false
	}
	listenHost, listenPort, err := net.SplitHostPort(strings.TrimSpace(listen))
	if err != nil || targetPort != listenPort {
		return false
	}

	targetHost = trimAddrHost(targetHost)
	listenHost = trimAddrHost(listenHost)
	if targetHost == "" || listenHost == "" {
		return false
	}
	if strings.EqualFold(targetHost, listenHost) {
		return true
	}
	if isUnspecifiedHost(listenHost) && isLocalHost(targetHost) {
		return true
	}
	if isLoopbackHost(listenHost) && isLoopbackHost(targetHost) {
		return true
	}
	return false
}

func targetLoopsToAnyPublicListener(target string, listens []string) bool {
	for _, listen := range listens {
		if targetLoopsToPublicListener(target, listen) {
			return true
		}
	}
	return false
}

func trimAddrHost(host string) string {
	return strings.Trim(strings.TrimSpace(host), "[]")
}

func isLocalHost(host string) bool {
	if strings.EqualFold(host, "localhost") {
		return true
	}
	ip := net.ParseIP(host)
	return ip != nil && (ip.IsLoopback() || ip.IsUnspecified())
}

func isLoopbackHost(host string) bool {
	if strings.EqualFold(host, "localhost") {
		return true
	}
	ip := net.ParseIP(host)
	return ip != nil && ip.IsLoopback()
}

func isUnspecifiedHost(host string) bool {
	ip := net.ParseIP(host)
	return ip != nil && ip.IsUnspecified()
}
