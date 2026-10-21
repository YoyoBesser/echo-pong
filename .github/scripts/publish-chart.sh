#!/usr/bin/env bash
# Package the chart at the release version and push it to <registry>/<owner>/charts (OCI). See docs/RELEASE.md#chart
set -euo pipefail
tag="$1" image="$2" registry="$3"
version="${tag#v}"
repo="oci://${image%/*}/charts"
plain=() && [[ "$registry" == localhost:* ]] && plain=(--plain-http)

helm dependency build helm/echo-pong
helm package helm/echo-pong --version "$version" --app-version "$tag" --destination "$RUNNER_TEMP"
printf '%s' "$GH_TOKEN" | helm registry login "$registry" -u "$GH_ACTOR" --password-stdin "${plain[@]}"
helm push "$RUNNER_TEMP/echo-pong-$version.tgz" "$repo" "${plain[@]}"
echo "pushed $repo/echo-pong:$version (appVersion $tag)"
