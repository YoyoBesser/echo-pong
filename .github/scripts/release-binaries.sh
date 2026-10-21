#!/usr/bin/env bash
# Release binaries: linux/{amd64,arm64} from the scanned image, darwin/{amd64,arm64} cross-compiled. See docs/RELEASE.md#binaries
set -euo pipefail
tag="$1" image="$2" out="$3"
root="$(cd "$(dirname "${BASH_SOURCE[0]}")/../.." && pwd)"
work="$(mktemp -d)"
mkdir -p "$out"

for arch in amd64 arm64; do
  "$root/.github/scripts/extract-binary.sh" "$image" "$arch" "$work/linux-$arch"
  CGO_ENABLED=0 GOOS=darwin GOARCH="$arch" go build -C "$root/src" -trimpath \
    -ldflags="-s -w -X main.version=$tag" -o "$work/darwin-$arch/ping-pong-app" .
done
for dir in "$work"/*; do
  platform="$(basename "$dir")"
  tar -czf "$out/ping-pong-app_${tag}_${platform/-/_}.tar.gz" -C "$dir" ping-pong-app
done
(cd "$out" && sha256sum ./*.tar.gz | sed 's| \./| |' > checksums.txt && cat checksums.txt)
rm -rf "$work"
