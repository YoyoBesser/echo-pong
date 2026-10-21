#!/usr/bin/env bash
# Release binaries: linux/{amd64,arm64}, copied out of the scanned, e2e-tested image. See docs/RELEASE.md#binaries
set -euo pipefail
tag="$1" image="$2" out="$3"
root="$(cd "$(dirname "${BASH_SOURCE[0]}")/../.." && pwd)"
work="$(mktemp -d)"
mkdir -p "$out"

for arch in amd64 arm64; do
  "$root/.github/scripts/extract-binary.sh" "$image" "$arch" "$work/$arch"
  tar -czf "$out/ping-pong-app_${tag}_linux_${arch}.tar.gz" -C "$work/$arch" ping-pong-app
done
(cd "$out" && sha256sum ./*.tar.gz | sed 's| \./| |' > checksums.txt && cat checksums.txt)
rm -rf "$work"
