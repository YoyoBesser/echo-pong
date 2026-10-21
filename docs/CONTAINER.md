# Container

Image built from [`src/Dockerfile`](../src/Dockerfile), with build context `src/`. [`src/.dockerignore`](../src/.dockerignore) is an allowlist: only `go.mod` and `*.go` enter the context.

## Contents

- [Base image](#base-image)
  - [Busybox](#busybox)
- [Cross-compile](#cross-compile)
- [Go toolchain](#go-toolchain)
- [Version](#version)
- [Non-root](#non-root)

## Base image

The runtime base is [distroless](https://github.com/GoogleContainerTools/distroless) `static-debian13:nonroot` plus a [busybox shell](#busybox). It's built as the `base` stage of the same Dockerfile (`docker build --target base src/`).

Distroless static has no package manager and no shell, only CA certs, tzdata, `/etc/passwd` and a `nonroot` user. A statically linked Go binary needs nothing else, so the attack surface and CVE count stay near zero.

### Busybox

`busybox:musl` (static, tracks the latest BusyBox release) is installed the standard way: the binary at `/usr/bin/busybox`, and one symlink per applet at its canonical path from `busybox --list-full`. So `/bin/sh`, `/bin/vi`, `/usr/bin/wget`, `/sbin/ip` and so on all work:

```sh
docker run --rm -it --entrypoint /bin/sh ghcr.io/yoyobesser/echo-pong:<tag>
kubectl -n echo-pong exec -it deploy/echo-pong -- sh
```

Distroless is usr-merged (`/bin` → `usr/bin`, `/sbin` → `usr/sbin`, both empty), so `bin/*` and `usr/bin/*` applets land in `/usr/bin`, and `sbin/*` and `usr/sbin/*` in `/usr/sbin`. They're reached through the base's own `/bin` and `/sbin` symlinks, and the default `PATH` already covers them.

Trade-off: a shell and `wget` in the production image help an attacker who gets code execution. The alternative is a shell-less image plus `kubectl debug` ephemeral containers, which keeps images minimal and brings tools only when needed.

The symlinks are created in a stage pinned to `$BUILDPLATFORM`, running the build host's own busybox. Only the target-arch binary is copied in, so no step executes target-arch code and cross-arch builds need no QEMU.

## Cross-compile

The Go build stage runs on `$BUILDPLATFORM` and cross-compiles with `GOOS=$TARGETOS GOARCH=$TARGETARCH CGO_ENABLED=0`. Go cross-compiles natively, which is much faster than building under QEMU emulation. `CGO_ENABLED=0` yields a static binary, so it runs on `static` with no libc. The same binary is the release artifact, and CI checks that it's static ([CI.md#static-binary](CI.md#static-binary)). `-trimpath -ldflags="-s -w"` strips local paths and debug symbols.

## Go toolchain

`src/go.mod` says `go 1.24`, the minimum language version (README L75), and `toolchain go1.27.3`, the compiler actually used. That `toolchain` line is the only place the Go version is pinned. Go 1.24 is end of life: building with it shipped 22 HIGH stdlib CVEs (net/http, crypto/tls, x509, ...) that are only fixed in Go ≥ 1.26.9 / 1.27.2. With go1.27.3, trivy reports none.

Everything reads that line:

- **Dockerfile:** the builder is `golang:1.24` (the language minimum) with `GOTOOLCHAIN=auto`. Go then downloads the `toolchain` version itself, verified against the Go checksum database. A `COPY go.mod` + `go version` layer caches that download until `go.mod` changes.
- **CI:** setup-go reads `toolchain`, so lint and tests use the same compiler as the image.
- **Locally:** any Go ≥ 1.24 switches to it automatically.

To bump Go, change the `toolchain` line only.

## Version

The binary carries its version, stamped at build time with `-ldflags "-X main.version=$VERSION"` from the Dockerfile's `VERSION` build arg (default `dev`):

| Built by | `VERSION` |
|---|---|
| CI (`app-ci.yml`) | commit short SHA |
| Release (`release.yml`) | the tag, e.g. `v1.2.3` |
| `scripts/minikube-up.sh` | `dev-<short-sha>[-dirty]` |

It shows up in `ping-pong-app --version`, the startup log line, and the `version` field of `/health`. That last one lets you check what a cluster is actually running: `curl <gateway>/health`.

## Non-root

`USER 65532:65532` is numeric on purpose. Kubernetes `runAsNonRoot: true` refuses to start a container whose image user is a name (`nonroot`), because the kubelet can't verify that a name isn't UID 0. A numeric UID can be checked.
