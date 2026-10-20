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
	secret     = "e2e-secret"
	secretPath = "/tmp/secret"
	secretEnv  = "SECRET_FILE_PATH=" + secretPath
)

var image = os.Getenv("E2E_IMAGE")

func TestMain(m *testing.M) {
	if image == "" {
		fmt.Fprintln(os.Stderr, "E2E_IMAGE must name the image under test")
		os.Exit(1)
	}
	os.Exit(m.Run())
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
