#!/usr/bin/env bash
# Copy the app binary for one arch out of a (multi-arch) image; fail unless static. See docs/CI.md#static-binary
set -euo pipefail
image="$1" arch="$2" out="$3"

# For a registry index, use that arch's own manifest digest: pulling one ref for two
# platforms can fail ("cannot overwrite digest"). See docs/CI.md#static-binary
repo="${image%%@*}" && [[ "${repo##*/}" == *:* ]] && repo="${repo%:*}"
platform_digest="$(docker buildx imagetools inspect --raw "$image" 2>/dev/null \
  | jq -r --arg arch "$arch" '.manifests[]? | select(.platform.os == "linux" and .platform.architecture == $arch) | .digest' \
  | head -1 || true)"
if [[ -n "$platform_digest" ]]; then
  ref="$repo@$platform_digest"
  docker pull --quiet "$ref" >/dev/null
else
  # Local-only image (e.g. minikube-up's build): pull only if that arch isn't already here.
  ref="$image"
  if [[ "$(docker image inspect --format '{{.Architecture}}' "$ref" 2>/dev/null)" != "$arch" ]]; then
    docker pull --quiet --platform "linux/$arch" "$ref" >/dev/null
  fi
fi
id="$(docker create --platform "linux/$arch" "$ref")"
trap 'docker rm "$id" >/dev/null' EXIT
mkdir -p "$out"
docker cp "$id:/usr/local/bin/ping-pong-app" "$out/ping-pong-app"
info="$(file "$out/ping-pong-app")"
echo "$info"
grep -q 'statically linked' <<< "$info" || { echo "::error::$arch binary is not statically linked"; exit 1; }
