package routing

import "testing"

func TestRouteLabelTreatsDiagnosticProbeAsSSHWS(t *testing.T) {
	req := HTTPRequest{
		Method:     "GET",
		Path:       "/diagnostic-probe",
		Upgrade:    "websocket",
		Connection: "upgrade",
	}
	if got := RouteLabel(req, ""); got != "ssh-ws-like" {
		t.Fatalf("RouteLabel() = %q, want ssh-ws-like", got)
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
		if got := RouteLabel(req, ""); got != "ssh-ws-like" {
			t.Fatalf("RouteLabel(%q) = %q, want ssh-ws-like", path, got)
		}
	}
}
