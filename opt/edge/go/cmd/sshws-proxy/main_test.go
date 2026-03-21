package main

import (
	"encoding/json"
	"os"
	"path/filepath"
	"reflect"
	"runtime"
	"strings"
	"testing"
	"time"
)

func TestConnectionRegistryAdmitAndReserveSeesPendingReservation(t *testing.T) {
	r := newConnectionRegistry()
	okResp := &admissionResponse{
		Allowed:  true,
		Username: "demo",
		Policy:   &policy{Username: "demo"},
	}

	first, res1, err := r.admitAndReserve("demo", "1.1.1.1", func(extraTotal int, extraIPs []string) (*admissionResponse, error) {
		if extraTotal != 0 {
			t.Fatalf("first extraTotal = %d, want 0", extraTotal)
		}
		if len(extraIPs) != 0 {
			t.Fatalf("first extraIPs = %v, want empty", extraIPs)
		}
		return okResp, nil
	})
	if err != nil || first == nil || res1 == nil {
		t.Fatalf("first reserve failed: resp=%v res=%v err=%v", first, res1, err)
	}
	defer r.finalize(res1)

	second, res2, err := r.admitAndReserve("demo", "2.2.2.2", func(extraTotal int, extraIPs []string) (*admissionResponse, error) {
		if extraTotal != 1 {
			t.Fatalf("second extraTotal = %d, want 1", extraTotal)
		}
		if !reflect.DeepEqual(extraIPs, []string{"1.1.1.1"}) {
			t.Fatalf("second extraIPs = %v, want [1.1.1.1]", extraIPs)
		}
		return okResp, nil
	})
	if err != nil || second == nil || res2 == nil {
		t.Fatalf("second reserve failed: resp=%v res=%v err=%v", second, res2, err)
	}
	r.finalize(res2)
}

func TestConnectionContextCurrentPolicyUsesRecentCacheOnHelperFailure(t *testing.T) {
	ctx := newConnectionContext(12345, "127.0.0.1:22022", "127.0.0.1", "demo", &controlClient{bin: "/definitely/missing-helper"}, nil)
	ctx.setInitialPolicy(&policy{Username: "demo", SpeedEnabled: true, SpeedUpBPS: 1024})

	got, err := ctx.currentPolicy()
	if err != nil {
		t.Fatalf("currentPolicy returned unexpected error with fresh cache: %v", err)
	}
	if got == nil || got.Username != "demo" || !got.SpeedEnabled {
		t.Fatalf("unexpected cached policy: %#v", got)
	}

	ctx.mu.Lock()
	ctx.policyCachedAt = time.Now().Add(-policyStaleGrace - time.Second)
	ctx.mu.Unlock()

	got, err = ctx.currentPolicy()
	if err == nil {
		t.Fatal("expected stale cache to fail after helper error")
	}
	if got != nil {
		t.Fatalf("expected nil policy on stale helper failure, got %#v", got)
	}
}

func TestControlClientSessionWritePassesProxyPID(t *testing.T) {
	dir := t.TempDir()
	argsPath := filepath.Join(dir, "args.txt")
	helper := filepath.Join(dir, "helper.sh")
	script := strings.Join([]string{
		"#!/bin/sh",
		"printf '%s\n' \"$@\" > \"" + argsPath + "\"",
		"printf '{\"ok\":true}\\n'",
	}, "\n")
	if err := os.WriteFile(helper, []byte(script), 0o755); err != nil {
		t.Fatalf("write helper: %v", err)
	}

	client := &controlClient{bin: helper, sessionRoot: dir}
	if err := client.sessionWrite(12345, "127.0.0.1:22022", "demo", "127.0.0.1", 424242); err != nil {
		t.Fatalf("sessionWrite failed: %v", err)
	}

	data, err := os.ReadFile(argsPath)
	if err != nil {
		t.Fatalf("read args: %v", err)
	}
	args := strings.Fields(string(data))
	found := false
	for i := 0; i+1 < len(args); i++ {
		if args[i] == "--proxy-pid" && args[i+1] == "424242" {
			found = true
			break
		}
	}
	if !found {
		t.Fatalf("expected --proxy-pid 424242 in args, got %v", args)
	}
}

func TestPythonSessionWriteUsesProvidedProxyPID(t *testing.T) {
	_, currentFile, _, ok := runtime.Caller(0)
	if !ok {
		t.Fatal("runtime.Caller failed")
	}
	repoRoot := filepath.Clean(filepath.Join(filepath.Dir(currentFile), "..", "..", "..", "..", ".."))
	helperPath := filepath.Join(repoRoot, "opt", "setup", "bin", "sshws-control.py")
	sessionRoot := t.TempDir()

	client := &controlClient{
		bin:         "python3",
		stateRoot:   sessionRoot,
		sessionRoot: sessionRoot,
	}
	orig := client.runJSON
	_ = orig

	var out map[string]any
	cmdArgs := []string{
		helperPath,
		"session-write",
		"--session-root", sessionRoot,
		"--backend-local-port", "12345",
		"--backend-target", "127.0.0.1:22022",
		"--username", "demo",
		"--client-ip", "127.0.0.1",
		"--proxy-pid", "999999",
	}
	if err := (&controlClient{bin: "python3"}).runJSON(sessionOpTimeout, cmdArgs, &out); err != nil {
		t.Fatalf("python helper session-write failed: %v", err)
	}

	data, err := os.ReadFile(filepath.Join(sessionRoot, "12345.json"))
	if err != nil {
		t.Fatalf("read session file: %v", err)
	}
	var payload map[string]any
	if err := json.Unmarshal(data, &payload); err != nil {
		t.Fatalf("unmarshal session payload: %v", err)
	}
	if got := int(payload["proxy_pid"].(float64)); got != 999999 {
		t.Fatalf("proxy_pid = %d, want 999999", got)
	}
}
