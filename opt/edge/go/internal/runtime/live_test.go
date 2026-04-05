package runtime

import "testing"

func TestLiveConfigDoesNotExposeMutableRoutingMaps(t *testing.T) {
	cfg := Config{
		SNIRoutes: map[string]string{
			"vmess.example.com": "vless_tcp",
		},
		SNIPassthrough: map[string]string{
			"vision.example.com": "127.0.0.1:8443",
		},
	}
	live := NewLive(cfg)

	cfg.SNIRoutes["vmess.example.com"] = "trojan_tcp"
	cfg.SNIPassthrough["vision.example.com"] = "127.0.0.1:9443"

	current := live.Config()
	if got := current.SNIRoutes["vmess.example.com"]; got != "vless_tcp" {
		t.Fatalf("live.Config().SNIRoutes = %q, want vless_tcp", got)
	}
	if got := current.SNIPassthrough["vision.example.com"]; got != "127.0.0.1:8443" {
		t.Fatalf("live.Config().SNIPassthrough = %q, want 127.0.0.1:8443", got)
	}

	current.SNIRoutes["vmess.example.com"] = "http"
	current.SNIPassthrough["vision.example.com"] = "127.0.0.1:10443"

	again := live.Config()
	if got := again.SNIRoutes["vmess.example.com"]; got != "vless_tcp" {
		t.Fatalf("second live.Config().SNIRoutes = %q, want vless_tcp", got)
	}
	if got := again.SNIPassthrough["vision.example.com"]; got != "127.0.0.1:8443" {
		t.Fatalf("second live.Config().SNIPassthrough = %q, want 127.0.0.1:8443", got)
	}
}

func TestLiveReloadReturnsIndependentConfigs(t *testing.T) {
	live := NewLive(Config{
		SNIRoutes: map[string]string{
			"old.example.com": "vless_tcp",
		},
	})

	oldCfg, newCfg, err := live.Reload(func() (Config, error) {
		return Config{
			SNIRoutes: map[string]string{
				"new.example.com": "trojan_tcp",
			},
			SNIPassthrough: map[string]string{
				"vision.example.com": "127.0.0.1:8443",
			},
		}, nil
	})
	if err != nil {
		t.Fatalf("Reload error = %v", err)
	}

	oldCfg.SNIRoutes["old.example.com"] = "http"
	newCfg.SNIRoutes["new.example.com"] = "xray_ws"
	newCfg.SNIPassthrough["vision.example.com"] = "127.0.0.1:9443"

	current := live.Config()
	if got := current.SNIRoutes["new.example.com"]; got != "trojan_tcp" {
		t.Fatalf("live.Config().SNIRoutes[new.example.com] = %q, want trojan_tcp", got)
	}
	if got := current.SNIPassthrough["vision.example.com"]; got != "127.0.0.1:8443" {
		t.Fatalf("live.Config().SNIPassthrough[vision.example.com] = %q, want 127.0.0.1:8443", got)
	}
	if _, ok := current.SNIRoutes["old.example.com"]; ok {
		t.Fatalf("live.Config() unexpectedly retained old route map entry")
	}
}
