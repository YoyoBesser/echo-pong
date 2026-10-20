//go:build e2e

package e2e

import (
	"strings"
	"testing"
)

func TestCLI(t *testing.T) {
	requireImage(t)
	withSecret := []string{"-e", secretEnv}

	cases := []struct {
		name     string
		opts     []string
		args     []string
		wantCode int
		wantOut  string
	}{
		{"help", nil, []string{"--help"}, 0, "USAGE:"},
		{"ping returns pong", withSecret, []string{"--mode=cli", "--password=" + secret, "ping"}, 0, `"message": "pong"`},
		{"pong returns ping", withSecret, []string{"--mode=cli", "--password=" + secret, "pong"}, 0, `"message": "ping"`},
		{"wrong password", withSecret, []string{"--mode=cli", "--password=nope", "ping"}, 1, "Invalid password"},
		{"missing password", withSecret, []string{"--mode=cli", "ping"}, 1, "Password is required"},
		{"no command", withSecret, []string{"--mode=cli", "--password=" + secret}, 1, "No command specified"},
		{"unknown command", withSecret, []string{"--mode=cli", "--password=" + secret, "serve"}, 1, "Unknown command: serve"},
		{"missing secret env", nil, []string{"--mode=cli", "--password=" + secret, "ping"}, 1, "SECRET_FILE_PATH environment variable not set"},
	}

	for _, tc := range cases {
		t.Run(tc.name, func(t *testing.T) {
			t.Parallel()
			id := createContainer(t, tc.opts, tc.args...)
			stdout, stderr, code, err := docker("start", "--attach", id)
			if err != nil {
				t.Fatal(err)
			}
			out := stdout + stderr
			if code != tc.wantCode {
				t.Errorf("exit code = %d, want %d\n%s", code, tc.wantCode, out)
			}
			if !strings.Contains(out, tc.wantOut) {
				t.Errorf("output missing %q\n%s", tc.wantOut, out)
			}
		})
	}
}
