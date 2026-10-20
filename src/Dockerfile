# syntax=docker/dockerfile:1

# Target-arch busybox binary (static, musl).
FROM busybox:musl AS busybox

# Applet symlinks made on the build platform, no QEMU. See docs/CONTAINER.md#busybox
FROM --platform=$BUILDPLATFORM busybox:musl AS busybox-rootfs
COPY --from=busybox /bin/busybox /rootfs/busybox/busybox
RUN for a in $(busybox --list); do [ "$a" = busybox ] || ln -s busybox "/rootfs/busybox/$a"; done

# Base: distroless static + busybox shell. See docs/CONTAINER.md#base-image
FROM gcr.io/distroless/static-debian13:nonroot AS base
COPY --from=busybox-rootfs /rootfs/ /
ENV PATH=/usr/local/sbin:/usr/local/bin:/usr/sbin:/usr/bin:/sbin:/bin:/busybox

# Cross-compile on the build platform. See docs/CONTAINER.md#cross-compile
FROM --platform=$BUILDPLATFORM golang:1.24 AS build
ARG TARGETOS TARGETARCH
WORKDIR /src
COPY go.mod *.go ./
RUN CGO_ENABLED=0 GOOS=$TARGETOS GOARCH=$TARGETARCH go build -trimpath -ldflags="-s -w" -o /out/ping-pong-app .

FROM base
COPY --from=build /out/ping-pong-app /usr/local/bin/ping-pong-app
# Numeric UID so k8s runAsNonRoot can verify it. See docs/CONTAINER.md#non-root
USER 65532:65532
EXPOSE 8080
ENTRYPOINT ["/usr/local/bin/ping-pong-app"]
    