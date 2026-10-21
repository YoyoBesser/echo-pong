# syntax=docker/dockerfile:1

# Target-arch busybox binary (static, musl).
FROM busybox:musl AS busybox

# Applets at their standard paths, mapped onto distroless's usr-merged /usr/{bin,sbin}; made on the
# build platform, no QEMU. See docs/CONTAINER.md#busybox
FROM --platform=$BUILDPLATFORM busybox:musl AS busybox-rootfs
COPY --from=busybox /bin/busybox /rootfs/usr/bin/busybox
RUN mkdir -p /rootfs/usr/sbin && for p in $(busybox --list-full); do \
      case "$p" in bin/* | usr/bin/*) d=usr/bin ;; sbin/* | usr/sbin/*) d=usr/sbin ;; *) continue ;; esac; \
      n="${p##*/}"; [ "$n" = busybox ] || ln -s /usr/bin/busybox "/rootfs/$d/$n"; \
    done

# Base: distroless static + busybox as /bin/sh. See docs/CONTAINER.md#base-image
FROM gcr.io/distroless/static-debian13:nonroot AS base
COPY --from=busybox-rootfs /rootfs/ /

# Cross-compile on the build platform. See docs/CONTAINER.md#cross-compile
# 1.24 = go.mod's language minimum; the compiler comes from its toolchain line. See docs/CONTAINER.md#go-toolchain
FROM --platform=$BUILDPLATFORM golang:1.24 AS build
ENV GOTOOLCHAIN=auto
ARG TARGETOS TARGETARCH
# Stamped into the binary (--version, /health). See docs/CONTAINER.md#version
ARG VERSION=dev
WORKDIR /src
COPY go.mod ./
# Fetches go.mod's toolchain; cached as a layer until go.mod changes.
RUN go version
COPY *.go ./
RUN CGO_ENABLED=0 GOOS=$TARGETOS GOARCH=$TARGETARCH go build -trimpath -ldflags="-s -w -X main.version=${VERSION}" -o /out/ping-pong-app .

FROM base
COPY --from=build /out/ping-pong-app /usr/local/bin/ping-pong-app
# Numeric UID so k8s runAsNonRoot can verify it. See docs/CONTAINER.md#non-root
USER 65532:65532
EXPOSE 8080
ENTRYPOINT ["/usr/local/bin/ping-pong-app"]
