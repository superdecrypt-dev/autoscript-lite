package routing

import "testing"

func TestRouteLabelTreatsDiagnosticProbeAsSSHWS(t *testing.T) {
	req := HTTPRequest{
		Method:     "GET",
		Path:       "/diagnostic-probe",
		Upgrade:    "websocket",
		Connection: "upgrade",
	}
	if got := RouteLabel(req, ""); got != "xray-ws-like" {
		t.Fatalf("RouteLabel() = %q, want xray-ws-like", got)
	}
}

func TestRouteLabelTreatsHexTokenWSPathAsSSHWSLike(t *testing.T) {
	tests := []string{"/a1b2c3d4e5", "/bebas/a1b2c3d4e5"}
	for _, path := range tests {
		req := HTTPRequest{
			Method:     "GET",
			Path:       path,
			Upgrade:    "websocket",
			Connection: "upgrade",
		}
		if got := RouteLabel(req, ""); got != "xray-ws-like" {
			t.Fatalf("RouteLabel(%q) = %q, want xray-ws-like", path, got)
		}
	}
}
