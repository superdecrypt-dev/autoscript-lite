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
