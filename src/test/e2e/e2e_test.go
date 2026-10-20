//go:build e2e

// Package e2e black-box tests a built image through docker. See docs/CI.md#e2e-tests
package e2e

import (
	"bytes"
	"errors"
	"fmt"
	"os"
	"os/exec"
	"path/filepath"
	"strings"
	"testing"
)

const (
	secretPath = "/tmp/secret"
	secretEnv  = "SECRET_FILE_PATH=" + secretPath
)

// Target: E2E_IMAGE runs containers; E2E_BASE_URL hits a live server instead. See docs/CI.md#e2e-tests
var (
	image   = os.Getenv("E2E_IMAGE")
	baseURL = os.Getenv("E2E_BASE_URL")
	secret  = envOr("E2E_SECRET", "e2e-secret")
)

func envOr(key, fallback string) string {
	if v := os.Getenv(key); v != "" {
		return v
	}
	return fallback
}

func TestMain(m *testing.M) {
	if image == "" && baseURL == "" {
		fmt.Fprintln(os.Stderr, "set E2E_IMAGE (image under test) or E2E_BASE_URL (live server)")
		os.Exit(1)
	}
	os.Exit(m.Run())
}

func requireImage(t *testing.T) {
	t.Helper()
	if image == "" {
		t.Skip("E2E_IMAGE not set")
	}
}

// docker runs a docker CLI command. Stdout and stderr stay separate: emulation warnings go to stderr.
func docker(args ...string) (stdout, stderr string, code int, err error) {
	var o, e bytes.Buffer
	cmd := exec.Command("docker", args...) //nolint:gosec // fixed binary, args from test code
	cmd.Stdout, cmd.Stderr = &o, &e
	err = cmd.Run()
	var exitErr *exec.ExitError
	if errors.As(err, &exitErr) {
		return o.String(), e.String(), exitErr.ExitCode(), nil
	}
	return o.String(), e.String(), 0, err
}

func mustDocker(t *testing.T, args ...string) string {
	t.Helper()
	out, errOut, code, err := docker(args...)
	if err != nil || code != 0 {
		t.Fatalf("docker %s: exit %d, err %v\n%s%s", strings.Join(args, " "), code, err, out, errOut)
	}
	return strings.TrimSpace(out)
}

// createContainer creates (not starts) a container and copies the secret file in.
// docker cp, not a bind mount, so it also works under act. See docs/LOCAL-TESTING.md#e2e
func createContainer(t *testing.T, opts []string, args ...string) string {
	t.Helper()
	id := mustDocker(t, append(append(append([]string{"create"}, opts...), image), args...)...)
	t.Cleanup(func() {
		if t.Failed() {
			out, errOut, _, _ := docker("logs", id)
			t.Logf("container logs:\n%s%s", out, errOut)
		}
		_, _, _, _ = docker("rm", "-f", id)
	})

	f := filepath.Join(t.TempDir(), "secret")
	// docker cp keeps the mode but chowns to root; UID 65532 needs read.
	if err := os.WriteFile(f, []byte(secret+"\n"), 0o644); err != nil { //nolint:gosec // see comment above
		t.Fatal(err)
	}
	mustDocker(t, "cp", f, id+":"+secretPath)
	return id
}
