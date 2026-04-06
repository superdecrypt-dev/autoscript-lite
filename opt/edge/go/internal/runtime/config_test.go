package runtime

import (
	"os"
	"path/filepath"
	"strings"
	"testing"
)

func TestParseSNIRoutesNormalizesEntries(t *testing.T) {
	routes, err := parseSNIRoutes("VMESS.EXAMPLE.COM.=vless-tcp, ws.example.com=xray_ws")
	if err != nil {
		t.Fatalf("parseSNIRoutes error = %v", err)
	}
	if got := routes["vmess.example.com"]; got != "vless_tcp" {
		t.Fatalf("vmess.example.com route = %q, want vless_tcp", got)
	}
	if got := routes["ws.example.com"]; got != "xray_ws" {
		t.Fatalf("ws.example.com route = %q, want xray_ws", got)
	}
}

func TestParseSNIRoutesRejectsDuplicateHost(t *testing.T) {
	if _, err := parseSNIRoutes("vmess.example.com=http,vmess.example.com=vless_tcp"); err == nil {
		t.Fatalf("parseSNIRoutes duplicate host error = nil, want error")
	}
}

func TestResolveSNIRouteMatchesNormalizedServerName(t *testing.T) {
	cfg := Config{
		SNIRoutes: map[string]string{
			"vmess.example.com": "vless_tcp",
		},
	}
	alias, ok := cfg.ResolveSNIRoute("VMESS.EXAMPLE.COM.")
	if !ok {
		t.Fatalf("ResolveSNIRoute ok = false, want true")
	}
	if alias != "vless_tcp" {
		t.Fatalf("ResolveSNIRoute alias = %q, want vless_tcp", alias)
	}
}

func TestParseSNIBackendMapNormalizesEntries(t *testing.T) {
	backends, err := parseSNIBackendMap("VISION.EXAMPLE.COM.=8443, tls.example.com=127.0.0.1:9443")
	if err != nil {
		t.Fatalf("parseSNIBackendMap error = %v", err)
	}
	if got := backends["vision.example.com"]; got != "127.0.0.1:8443" {
		t.Fatalf("vision.example.com backend = %q, want 127.0.0.1:8443", got)
	}
	if got := backends["tls.example.com"]; got != "127.0.0.1:9443" {
		t.Fatalf("tls.example.com backend = %q, want 127.0.0.1:9443", got)
	}
}

func TestResolveSNIPassthroughMatchesNormalizedServerName(t *testing.T) {
	cfg := Config{
		SNIPassthrough: map[string]string{
			"vision.example.com": "127.0.0.1:8443",
		},
	}
	target, ok := cfg.ResolveSNIPassthrough("VISION.EXAMPLE.COM.")
	if !ok {
		t.Fatalf("ResolveSNIPassthrough ok = false, want true")
	}
	if target != "127.0.0.1:8443" {
		t.Fatalf("ResolveSNIPassthrough target = %q, want 127.0.0.1:8443", target)
	}
}

func TestValidateRejectsInvalidSNIRouteAlias(t *testing.T) {
	cfg := Config{
		Provider:             "go",
		PublicHTTPAddr:       "0.0.0.0:80",
		PublicTLSAddr:        "0.0.0.0:443",
		MetricsEnabled:       false,
		HTTPBackend:          "127.0.0.1:18080",
		XrayDirectBackend:    "127.0.0.1:22022",
		XrayTLSBackend:       "127.0.0.1:22443",
		XrayWSBackend:        "127.0.0.1:10015",
		VLESSRawBackend:      "127.0.0.1:33175",
		TrojanRawBackend:     "127.0.0.1:48778",
		TLSCertFile:          "/opt/cert/fullchain.pem",
		TLSKeyFile:           "/opt/cert/privkey.pem",
		DetectTimeout:        defaultDetectTimeout,
		TLSHandshakeTimeout:  defaultTLSHandshakeTimeout,
		XraySessionHeartbeat: defaultXraySessionHeartbeat,
		AcceptRateWindow:     defaultAcceptRateWindow,
		CooldownWindow:       defaultCooldownWindow,
		CooldownDuration:     defaultCooldownDuration,
		SNIRoutes: map[string]string{
			"vmess.example.com": "bogus",
		},
	}
	if err := cfg.Validate(); err == nil {
		t.Fatalf("Validate error = nil, want invalid SNI route alias error")
	}
}

func TestValidateRejectsOverlappingSNIHost(t *testing.T) {
	cfg := Config{
		Provider:             "go",
		PublicHTTPAddr:       "0.0.0.0:80",
		PublicTLSAddr:        "0.0.0.0:443",
		MetricsEnabled:       false,
		HTTPBackend:          "127.0.0.1:18080",
		XrayDirectBackend:    "127.0.0.1:22022",
		XrayTLSBackend:       "127.0.0.1:22443",
		XrayWSBackend:        "127.0.0.1:10015",
		VLESSRawBackend:      "127.0.0.1:33175",
		TrojanRawBackend:     "127.0.0.1:48778",
		TLSCertFile:          "/opt/cert/fullchain.pem",
		TLSKeyFile:           "/opt/cert/privkey.pem",
		DetectTimeout:        defaultDetectTimeout,
		TLSHandshakeTimeout:  defaultTLSHandshakeTimeout,
		XraySessionHeartbeat: defaultXraySessionHeartbeat,
		AcceptRateWindow:     defaultAcceptRateWindow,
		CooldownWindow:       defaultCooldownWindow,
		CooldownDuration:     defaultCooldownDuration,
		SNIRoutes: map[string]string{
			"vision.example.com": "vless_tcp",
		},
		SNIPassthrough: map[string]string{
			"vision.example.com": "127.0.0.1:8443",
		},
	}
	if err := cfg.Validate(); err == nil {
		t.Fatalf("Validate error = nil, want overlapping SNI host error")
	}
}

func TestValidateRejectsPassthroughLoopToPublicTLSListener(t *testing.T) {
	cfg := Config{
		Provider:             "go",
		PublicHTTPAddr:       "0.0.0.0:80",
		PublicTLSAddr:        "0.0.0.0:443",
		MetricsEnabled:       false,
		HTTPBackend:          "127.0.0.1:18080",
		XrayDirectBackend:    "127.0.0.1:22022",
		XrayTLSBackend:       "127.0.0.1:22443",
		XrayWSBackend:        "127.0.0.1:10015",
		VLESSRawBackend:      "127.0.0.1:33175",
		TrojanRawBackend:     "127.0.0.1:48778",
		TLSCertFile:          "/opt/cert/fullchain.pem",
		TLSKeyFile:           "/opt/cert/privkey.pem",
		DetectTimeout:        defaultDetectTimeout,
		TLSHandshakeTimeout:  defaultTLSHandshakeTimeout,
		XraySessionHeartbeat: defaultXraySessionHeartbeat,
		AcceptRateWindow:     defaultAcceptRateWindow,
		CooldownWindow:       defaultCooldownWindow,
		CooldownDuration:     defaultCooldownDuration,
		SNIPassthrough: map[string]string{
			"vision.example.com": "127.0.0.1:443",
		},
	}
	if err := cfg.Validate(); err == nil {
		t.Fatalf("Validate error = nil, want passthrough self-loop error")
	}
}

func TestValidateRejectsPassthroughLoopToPublicHTTPListener(t *testing.T) {
	cfg := Config{
		Provider:             "go",
		PublicHTTPAddr:       "0.0.0.0:80",
		PublicTLSAddr:        "0.0.0.0:443",
		MetricsEnabled:       false,
		HTTPBackend:          "127.0.0.1:18080",
		XrayDirectBackend:    "127.0.0.1:22022",
		XrayTLSBackend:       "127.0.0.1:22443",
		XrayWSBackend:        "127.0.0.1:10015",
		VLESSRawBackend:      "127.0.0.1:33175",
		TrojanRawBackend:     "127.0.0.1:48778",
		TLSCertFile:          "/opt/cert/fullchain.pem",
		TLSKeyFile:           "/opt/cert/privkey.pem",
		DetectTimeout:        defaultDetectTimeout,
		TLSHandshakeTimeout:  defaultTLSHandshakeTimeout,
		XraySessionHeartbeat: defaultXraySessionHeartbeat,
		AcceptRateWindow:     defaultAcceptRateWindow,
		CooldownWindow:       defaultCooldownWindow,
		CooldownDuration:     defaultCooldownDuration,
		SNIPassthrough: map[string]string{
			"legacy.example.com": "localhost:80",
		},
	}
	if err := cfg.Validate(); err == nil {
		t.Fatalf("Validate error = nil, want passthrough http self-loop error")
	}
}

func TestConfigCloneDeepCopiesRoutingMaps(t *testing.T) {
	cfg := Config{
		TrustedProxyCIDRs: []string{"127.0.0.1/32"},
		SNIRoutes: map[string]string{
			"vmess.example.com": "vless_tcp",
		},
		SNIPassthrough: map[string]string{
			"vision.example.com": "127.0.0.1:8443",
		},
	}

	clone := cfg.Clone()
	clone.TrustedProxyCIDRs[0] = "10.0.0.0/8"
	clone.SNIRoutes["vmess.example.com"] = "trojan_tcp"
	clone.SNIPassthrough["vision.example.com"] = "127.0.0.1:9443"

	if got := cfg.TrustedProxyCIDRs[0]; got != "127.0.0.1/32" {
		t.Fatalf("TrustedProxyCIDRs[0] = %q, want 127.0.0.1/32", got)
	}
	if got := cfg.SNIRoutes["vmess.example.com"]; got != "vless_tcp" {
		t.Fatalf("SNIRoutes[vmess.example.com] = %q, want vless_tcp", got)
	}
	if got := cfg.SNIPassthrough["vision.example.com"]; got != "127.0.0.1:8443" {
		t.Fatalf("SNIPassthrough[vision.example.com] = %q, want 127.0.0.1:8443", got)
	}
}

func TestMergeEnvSourceUsesRuntimeFileAsAuthoritativeForEdgeKeys(t *testing.T) {
	process := envSource{
		"EDGE_RUNTIME_ENV_FILE": "/etc/default/edge-runtime",
		"EDGE_SNI_ROUTES":       "reload-a.example=http",
		"EDGE_SNI_PASSTHROUGH":  "reload-pass-a.example=127.0.0.1:18443",
		"EDGE_PUBLIC_TLS_PORT":  "443",
		"PATH":                  "/usr/bin",
	}
	file := map[string]string{
		"EDGE_PUBLIC_TLS_PORT": "443",
	}

	merged := mergeEnvSource(process, file, "/etc/default/edge-runtime")

	if _, ok := merged["EDGE_SNI_ROUTES"]; ok {
		t.Fatalf("merged EDGE_SNI_ROUTES unexpectedly retained process env value")
	}
	if _, ok := merged["EDGE_SNI_PASSTHROUGH"]; ok {
		t.Fatalf("merged EDGE_SNI_PASSTHROUGH unexpectedly retained process env value")
	}
	if got := merged["EDGE_PUBLIC_TLS_PORT"]; got != "443" {
		t.Fatalf("merged EDGE_PUBLIC_TLS_PORT = %q, want 443", got)
	}
	if got := merged["PATH"]; got != "/usr/bin" {
		t.Fatalf("merged PATH = %q, want /usr/bin", got)
	}
	if got := merged["EDGE_RUNTIME_ENV_FILE"]; got != "/etc/default/edge-runtime" {
		t.Fatalf("merged EDGE_RUNTIME_ENV_FILE = %q, want /etc/default/edge-runtime", got)
	}
}

func TestEnvListenAddrsPromotesSinglePortWhenListAlsoPresent(t *testing.T) {
	source := envSource{
		"EDGE_PUBLIC_HTTP_PORT":  "8080",
		"EDGE_PUBLIC_HTTP_PORTS": "80,2052",
	}

	addrs, primary, err := envListenAddrs(
		source,
		"EDGE_PUBLIC_HTTP_PORTS",
		"EDGE_PUBLIC_HTTP_PORT",
		defaultPublicHTTPPorts,
		defaultPublicHTTPAddr,
		"0.0.0.0",
	)
	if err != nil {
		t.Fatalf("envListenAddrs error = %v", err)
	}
	if primary != "0.0.0.0:8080" {
		t.Fatalf("primary = %q, want 0.0.0.0:8080", primary)
	}
	if len(addrs) != 3 {
		t.Fatalf("len(addrs) = %d, want 3", len(addrs))
	}
	want := []string{"0.0.0.0:8080", "0.0.0.0:80", "0.0.0.0:2052"}
	for i, addr := range want {
		if addrs[i] != addr {
			t.Fatalf("addrs[%d] = %q, want %q", i, addrs[i], addr)
		}
	}
}

func TestEnvListenAddrsKeepsSinglePortUniqueWhenAlreadyInList(t *testing.T) {
	source := envSource{
		"EDGE_PUBLIC_TLS_PORT":  "2053",
		"EDGE_PUBLIC_TLS_PORTS": "443,2053,2083",
	}

	addrs, primary, err := envListenAddrs(
		source,
		"EDGE_PUBLIC_TLS_PORTS",
		"EDGE_PUBLIC_TLS_PORT",
		defaultPublicTLSPorts,
		defaultPublicTLSAddr,
		"0.0.0.0",
	)
	if err != nil {
		t.Fatalf("envListenAddrs error = %v", err)
	}
	if primary != "0.0.0.0:2053" {
		t.Fatalf("primary = %q, want 0.0.0.0:2053", primary)
	}
	want := []string{"0.0.0.0:2053", "0.0.0.0:443", "0.0.0.0:2083"}
	if len(addrs) != len(want) {
		t.Fatalf("len(addrs) = %d, want %d", len(addrs), len(want))
	}
	for i, addr := range want {
		if addrs[i] != addr {
			t.Fatalf("addrs[%d] = %q, want %q", i, addrs[i], addr)
		}
	}
}

func TestLoadConfigReturnsDiscoveryErrorWhenXrayInboundsFileMissing(t *testing.T) {
	envFile := filepath.Join(t.TempDir(), "edge-runtime.env")
	writeConfigTestFile(t, envFile, "EDGE_XRAY_INBOUNDS_FILE=/tmp/does-not-exist-raw-inbounds.json\n")
	t.Setenv("EDGE_RUNTIME_ENV_FILE", envFile)

	_, err := LoadConfig()
	if err == nil {
		t.Fatal("LoadConfig error = nil, want discovery error")
	}
	if !strings.Contains(err.Error(), "discover raw backends") {
		t.Fatalf("LoadConfig error = %q, want discovery context", err)
	}
}

func TestLoadConfigKeepsExplicitRawBackendsWithoutDiscoveryFile(t *testing.T) {
	envFile := filepath.Join(t.TempDir(), "edge-runtime.env")
	writeConfigTestFile(t, envFile, strings.Join([]string{
		"EDGE_XRAY_INBOUNDS_FILE=/tmp/does-not-exist-raw-inbounds.json",
		"EDGE_XRAY_VLESS_RAW_BACKEND=10.10.10.5:443",
		"EDGE_XRAY_TROJAN_RAW_BACKEND=10.10.10.6:443",
	}, "\n")+"\n")
	t.Setenv("EDGE_RUNTIME_ENV_FILE", envFile)

	cfg, err := LoadConfig()
	if err != nil {
		t.Fatalf("LoadConfig error = %v", err)
	}
	if cfg.VLESSRawBackend != "10.10.10.5:443" {
		t.Fatalf("VLESSRawBackend = %q, want 10.10.10.5:443", cfg.VLESSRawBackend)
	}
	if cfg.TrojanRawBackend != "10.10.10.6:443" {
		t.Fatalf("TrojanRawBackend = %q, want 10.10.10.6:443", cfg.TrojanRawBackend)
	}
}

func TestLoadConfigGoProviderDefaultsTLSAndFallbackToHTTPBackend(t *testing.T) {
	envFile := filepath.Join(t.TempDir(), "edge-runtime.env")
	writeConfigTestFile(t, envFile, strings.Join([]string{
		"EDGE_PROVIDER=go",
		"EDGE_NGINX_HTTP_BACKEND=127.0.0.1:19080",
		"EDGE_XRAY_VLESS_RAW_BACKEND=10.10.10.5:443",
		"EDGE_XRAY_TROJAN_RAW_BACKEND=10.10.10.6:443",
	}, "\n")+"\n")
	t.Setenv("EDGE_RUNTIME_ENV_FILE", envFile)

	cfg, err := LoadConfig()
	if err != nil {
		t.Fatalf("LoadConfig error = %v", err)
	}
	if cfg.XrayTLSBackend != "127.0.0.1:19080" {
		t.Fatalf("XrayTLSBackend = %q, want 127.0.0.1:19080", cfg.XrayTLSBackend)
	}
}

func TestLoadConfigGoProviderNormalizesLegacyTLSBackendPattern(t *testing.T) {
	envFile := filepath.Join(t.TempDir(), "edge-runtime.env")
	writeConfigTestFile(t, envFile, strings.Join([]string{
		"EDGE_PROVIDER=go",
		"EDGE_NGINX_HTTP_BACKEND=127.0.0.1:18080",
		"EDGE_NGINX_TLS_BACKEND=127.0.0.1:18443",
		"EDGE_XRAY_DIRECT_BACKEND=127.0.0.1:18080",
		"EDGE_XRAY_WS_BACKEND=127.0.0.1:18080",
		"EDGE_XRAY_TLS_BACKEND=127.0.0.1:18443",
		"EDGE_XRAY_VLESS_RAW_BACKEND=10.10.10.5:443",
		"EDGE_XRAY_TROJAN_RAW_BACKEND=10.10.10.6:443",
	}, "\n")+"\n")
	t.Setenv("EDGE_RUNTIME_ENV_FILE", envFile)

	cfg, err := LoadConfig()
	if err != nil {
		t.Fatalf("LoadConfig error = %v", err)
	}
	if cfg.XrayTLSBackend != "127.0.0.1:18080" {
		t.Fatalf("XrayTLSBackend = %q, want 127.0.0.1:18080", cfg.XrayTLSBackend)
	}
}

func TestLoadConfigGoProviderKeepsCustomTLSOverridePattern(t *testing.T) {
	envFile := filepath.Join(t.TempDir(), "edge-runtime.env")
	writeConfigTestFile(t, envFile, strings.Join([]string{
		"EDGE_PROVIDER=go",
		"EDGE_NGINX_HTTP_BACKEND=127.0.0.1:19080",
		"EDGE_NGINX_TLS_BACKEND=127.0.0.1:19443",
		"EDGE_XRAY_DIRECT_BACKEND=127.0.0.1:19080",
		"EDGE_XRAY_WS_BACKEND=127.0.0.1:19080",
		"EDGE_XRAY_TLS_BACKEND=127.0.0.1:19443",
		"EDGE_XRAY_VLESS_RAW_BACKEND=10.10.10.5:443",
		"EDGE_XRAY_TROJAN_RAW_BACKEND=10.10.10.6:443",
	}, "\n")+"\n")
	t.Setenv("EDGE_RUNTIME_ENV_FILE", envFile)

	cfg, err := LoadConfig()
	if err != nil {
		t.Fatalf("LoadConfig error = %v", err)
	}
	if cfg.XrayTLSBackend != "127.0.0.1:19443" {
		t.Fatalf("XrayTLSBackend = %q, want 127.0.0.1:19443", cfg.XrayTLSBackend)
	}
}

func writeConfigTestFile(t *testing.T, path, content string) {
	t.Helper()
	if err := os.WriteFile(path, []byte(content), 0o600); err != nil {
		t.Fatalf("WriteFile(%s): %v", path, err)
	}
}
