#!/usr/bin/env bash
# Copy the app binary for one arch out of a (multi-arch) image; fail unless static. See docs/CI.md#static-binary
set -euo pipefail
image="$1" arch="$2" out="$3"

# Pull unless that arch is already local (e.g. a locally built image).
if [[ "$(docker image inspect --format '{{.Architecture}}' "$image" 2>/dev/null)" != "$arch" ]]; then
  docker pull --quiet --platform "linux/$arch" "$image" >/dev/null
fi
id="$(docker create --platform "linux/$arch" "$image")"
trap 'docker rm "$id" >/dev/null' EXIT
mkdir -p "$out"
docker cp "$id:/usr/local/bin/ping-pong-app" "$out/ping-pong-app"
info="$(file "$out/ping-pong-app")"
echo "$info"
grep -q 'statically linked' <<< "$info" || { echo "::error::$arch binary is not statically linked"; exit 1; }
