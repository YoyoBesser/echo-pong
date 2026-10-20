# Container

Image built from [`src/Dockerfile`](../src/Dockerfile), with build context `src/`. [`src/.dockerignore`](../src/.dockerignore) is an allowlist: only `go.mod` and `*.go` enter the context.

## Base image

The runtime base is [distroless](https://github.com/GoogleContainerTools/distroless) `static-debian13:nonroot` plus a [busybox shell](#busybox). It's built as the `base` stage of the same Dockerfile (`docker build --target base src/`).

Distroless static has no package manager and no shell, only CA certs, tzdata, `/etc/passwd` and a `nonroot` user. A statically linked Go binary needs nothing else, so the attack surface and CVE count stay near zero.

### Busybox

`busybox:musl` (static, tracks the latest BusyBox release) is copied to `/busybox/`, with one symlink per applet and `/busybox` appended to `PATH`. This matches the layout of distroless's own `:debug` images, but with the current BusyBox instead of whatever version distroless last pinned.

It gives `kubectl exec ... -- sh`, `wget` and `nc` for debugging inside the pod.

Trade-off: a shell and `wget` in the production image help an attacker who gets code execution. The alternative is a shell-less image plus `kubectl debug` ephemeral containers, which keeps prod images minimal and brings tools only when needed.

The symlinks are created in a stage pinned to `$BUILDPLATFORM`, running the build host's own busybox. Only the target-arch binary is copied in, so no step executes target-arch code and cross-arch builds need no QEMU.

## Cross-compile

The Go build stage runs on `$BUILDPLATFORM` and cross-compiles with `GOOS=$TARGETOS GOARCH=$TARGETARCH CGO_ENABLED=0`. Go cross-compiles natively, which is much faster than building under QEMU emulation. `CGO_ENABLED=0` yields a static binary, so it runs on `static` with no libc. The same binary is the release artifact, and CI checks that it's static ([CI.md#static-binary](CI.md#static-binary)). `-trimpath -ldflags="-s -w"` strips local paths and debug symbols.

## Go toolchain

`src/go.mod` says `go 1.24`, the minimum language version (README L75), and `toolchain go1.27.3`, the compiler actually used. The build stage's `golang:1.27.3` tag matches the toolchain line. Go 1.24 is end of life: building with it shipped 22 HIGH stdlib CVEs (net/http, crypto/tls, x509, ...) that are only fixed in Go ≥ 1.26.9 / 1.27.2. With go1.27.3, trivy and govulncheck report none.

The language version stays 1.24, so the code still builds with any Go ≥ 1.24. CI picks the toolchain from the same line (setup-go reads `toolchain`), so the linters, govulncheck and the image all see the same stdlib. Bump both lines together.

## Non-root

`USER 65532:65532` is numeric on purpose. Kubernetes `runAsNonRoot: true` refuses to start a container whose image user is a name (`nonroot`), because the kubelet can't verify that a name isn't UID 0. A numeric UID can be checked.
