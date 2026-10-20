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

The Go build stage runs on `$BUILDPLATFORM` and cross-compiles with `GOOS=$TARGETOS GOARCH=$TARGETARCH CGO_ENABLED=0`. Go cross-compiles natively, which is much faster than building under QEMU emulation. `CGO_ENABLED=0` yields a static binary, so it runs on `static` with no libc. `-trimpath -ldflags="-s -w"` strips local paths and debug symbols.

## Non-root

`USER 65532:65532` is numeric on purpose. Kubernetes `runAsNonRoot: true` refuses to start a container whose image user is a name (`nonroot`), because the kubelet can't verify that a name isn't UID 0. A numeric UID can be checked.
