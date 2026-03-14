package runtime

import "testing"

func TestParseSNIRoutesNormalizesEntries(t *testing.T) {
	routes, err := parseSNIRoutes("VMESS.EXAMPLE.COM.=vless-tcp, ssh.example.com=ssh_ws")
	if err != nil {
		t.Fatalf("parseSNIRoutes error = %v", err)
	}
	if got := routes["vmess.example.com"]; got != "vless_tcp" {
		t.Fatalf("vmess.example.com route = %q, want vless_tcp", got)
	}
	if got := routes["ssh.example.com"]; got != "ssh_ws" {
		t.Fatalf("ssh.example.com route = %q, want ssh_ws", got)
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
		Provider:            "go",
		PublicHTTPAddr:      "0.0.0.0:80",
		PublicTLSAddr:       "0.0.0.0:443",
		MetricsEnabled:      false,
		HTTPBackend:         "127.0.0.1:18080",
		SSHBackend:          "127.0.0.1:22022",
		SSHTLSBackend:       "127.0.0.1:22443",
		SSHWSBackend:        "127.0.0.1:10015",
		VLESSRawBackend:     "127.0.0.1:33175",
		TrojanRawBackend:    "127.0.0.1:48778",
		TLSCertFile:         "/opt/cert/fullchain.pem",
		TLSKeyFile:          "/opt/cert/privkey.pem",
		DetectTimeout:       defaultDetectTimeout,
		TLSHandshakeTimeout: defaultTLSHandshakeTimeout,
		SSHSessionHeartbeat: defaultSSHSessionHeartbeat,
		AcceptRateWindow:    defaultAcceptRateWindow,
		CooldownWindow:      defaultCooldownWindow,
		CooldownDuration:    defaultCooldownDuration,
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
		Provider:            "go",
		PublicHTTPAddr:      "0.0.0.0:80",
		PublicTLSAddr:       "0.0.0.0:443",
		MetricsEnabled:      false,
		HTTPBackend:         "127.0.0.1:18080",
		SSHBackend:          "127.0.0.1:22022",
		SSHTLSBackend:       "127.0.0.1:22443",
		SSHWSBackend:        "127.0.0.1:10015",
		VLESSRawBackend:     "127.0.0.1:33175",
		TrojanRawBackend:    "127.0.0.1:48778",
		TLSCertFile:         "/opt/cert/fullchain.pem",
		TLSKeyFile:          "/opt/cert/privkey.pem",
		DetectTimeout:       defaultDetectTimeout,
		TLSHandshakeTimeout: defaultTLSHandshakeTimeout,
		SSHSessionHeartbeat: defaultSSHSessionHeartbeat,
		AcceptRateWindow:    defaultAcceptRateWindow,
		CooldownWindow:      defaultCooldownWindow,
		CooldownDuration:    defaultCooldownDuration,
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
