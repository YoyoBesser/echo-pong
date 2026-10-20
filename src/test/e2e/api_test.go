//go:build e2e

package e2e

import (
	"encoding/json"
	"io"
	"net/http"
	"strings"
	"testing"
	"time"
)

// Server sleeps 10s before listening (README L32), so allow generous startup.
const startupTimeout = 45 * time.Second

func TestAPI(t *testing.T) {
	id := createContainer(t, []string{"-e", secretEnv, "-p", "127.0.0.1::8080"})
	mustDocker(t, "start", id)
	base := "http://" + mustDocker(t, "port", id, "8080/tcp")
	waitHealthy(t, base)

	cases := []struct {
		name        string
		path        string
		auth        string
		wantStatus  int
		wantType    string
		wantMessage string
		wantBody    string
	}{
		{"health is public", "/health", "", http.StatusOK, "application/json", "", `"status":"healthy"`},
		{"root serves docs", "/", "", http.StatusOK, "text/html", "", "Ping Pong Game API"},
		{"ping without auth", "/ping", "", http.StatusUnauthorized, "application/json", "", "Authorization header required"},
		{"ping with wrong token", "/ping", "Bearer nope", http.StatusUnauthorized, "application/json", "", "Invalid authorization token"},
		{"ping with raw token", "/ping", secret, http.StatusOK, "application/json", "pong", ""},
		{"ping with bearer token", "/ping", "Bearer " + secret, http.StatusOK, "application/json", "pong", ""},
		{"pong with bearer token", "/pong", "Bearer " + secret, http.StatusOK, "application/json", "ping", ""},
		{"pong without auth", "/pong", "", http.StatusUnauthorized, "application/json", "", "Authorization header required"},
	}

	for _, tc := range cases {
		t.Run(tc.name, func(t *testing.T) {
			status, ctype, body := get(t, base+tc.path, tc.auth)
			if status != tc.wantStatus {
				t.Errorf("status = %d, want %d\n%s", status, tc.wantStatus, body)
			}
			if !strings.HasPrefix(ctype, tc.wantType) {
				t.Errorf("Content-Type = %q, want %q", ctype, tc.wantType)
			}
			if tc.wantBody != "" && !strings.Contains(body, tc.wantBody) {
				t.Errorf("body missing %q\n%s", tc.wantBody, body)
			}
			if tc.wantMessage != "" {
				var r struct {
					Message string `json:"message"`
				}
				if err := json.Unmarshal([]byte(body), &r); err != nil {
					t.Fatalf("decode %q: %v", body, err)
				}
				if r.Message != tc.wantMessage {
					t.Errorf("message = %q, want %q", r.Message, tc.wantMessage)
				}
			}
		})
	}
}

func waitHealthy(t *testing.T, base string) {
	t.Helper()
	deadline := time.Now().Add(startupTimeout)
	for time.Now().Before(deadline) {
		resp, err := http.Get(base + "/health") //nolint:gosec // URL built from docker port output
		if err == nil {
			_ = resp.Body.Close()
			if resp.StatusCode == http.StatusOK {
				return
			}
		}
		time.Sleep(500 * time.Millisecond)
	}
	t.Fatalf("%s/health not ready after %s", base, startupTimeout)
}

func get(t *testing.T, url, auth string) (int, string, string) {
	t.Helper()
	req, err := http.NewRequest(http.MethodGet, url, nil)
	if err != nil {
		t.Fatal(err)
	}
	if auth != "" {
		req.Header.Set("Authorization", auth)
	}
	resp, err := http.DefaultClient.Do(req)
	if err != nil {
		t.Fatal(err)
	}
	defer func() { _ = resp.Body.Close() }()
	body, err := io.ReadAll(resp.Body)
	if err != nil {
		t.Fatal(err)
	}
	return resp.StatusCode, resp.Header.Get("Content-Type"), string(body)
}
