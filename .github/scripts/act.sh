#!/usr/bin/env bash
# Run a workflow (or one job) under act with local stand-ins for GitHub. See docs/LOCAL-TESTING.md#act-wrapper
set -euo pipefail

REGISTRY_IMAGE="registry:3.1.2"  # latest: https://github.com/distribution/distribution/releases (checked 2026-10-21)
REGISTRY_NAME=act-registry
REGISTRY_PORT="${REGISTRY_PORT:-5000}"
KEEP_REGISTRY="${KEEP_REGISTRY:-0}"

usage() {
  cat <<'USAGE'
usage: .github/scripts/act.sh <workflow> [job] [--pr] [--arch amd64|arm64] [-- <extra act args>]

  workflow  file name in .github/workflows/ without .yml (app-ci, helm-ci, github-ci, release, cd)
  job       run only this job; act runs its needs first
  --pr      simulate pull_request (head = current branch + HEAD) instead of push
  --arch    run only that matrix arch

env: REGISTRY_PORT (default 5000), KEEP_REGISTRY=1 to leave the local registry running
USAGE
}

log() { printf '==> %s\n' "$*" >&2; }

workflow="" job="" event=push arch="" extra=()
while (($#)); do
  case "$1" in
    -h | --help) usage; exit 0 ;;
    --pr) event=pull_request ;;
    --arch) arch="${2:?--arch needs a value}"; shift ;;
    --) shift; extra=("$@"); break ;;
    -*) echo "unknown flag: $1" >&2; usage >&2; exit 2 ;;
    *) if [[ -z "$workflow" ]]; then workflow="$1"; elif [[ -z "$job" ]]; then job="$1"; else usage >&2; exit 2; fi ;;
  esac
  shift
done
[[ -n "$workflow" ]] || { usage >&2; exit 2; }

root="$(git rev-parse --show-toplevel)"
cd "$root"
wf=".github/workflows/$workflow.yml"
[[ -f "$wf" ]] || { echo "no such workflow: $wf" >&2; exit 2; }
for bin in act docker gh git jq; do command -v "$bin" >/dev/null || { echo "missing: $bin" >&2; exit 2; }; done

tmp="$(mktemp -d)"
started_registry=0
cleanup() {
  if [[ "$started_registry" == 1 && "$KEEP_REGISTRY" != 1 ]]; then
    docker rm -f "$REGISTRY_NAME" >/dev/null 2>&1 || true
  fi
  rm -rf "$tmp"
}
trap cleanup EXIT

# Stand-in for GHCR: CI pushes and the trivy plugin pulls here, never to the real registry.
if [[ -z "$(docker ps -q -f "name=^$REGISTRY_NAME$")" ]]; then
  log "start $REGISTRY_IMAGE on localhost:$REGISTRY_PORT"
  docker run -d --rm --name "$REGISTRY_NAME" -p "$REGISTRY_PORT:5000" "$REGISTRY_IMAGE" >/dev/null
  started_registry=1
fi

event_file="$tmp/event.json"
if [[ "$event" == pull_request ]]; then
  jq -n --arg ref "$(git branch --show-current)" --arg sha "$(git rev-parse HEAD)" \
    '{pull_request: {head: {ref: $ref, sha: $sha}, base: {ref: "main"}}}' > "$event_file"
else
  echo '{}' > "$event_file"
fi

args=(
  "$event" -W "$wf" -e "$event_file"
  --var "CI_IMAGE=localhost:$REGISTRY_PORT/echo-pong"
  # act clones remote actions with it; pushes still go to the local registry.
  -s "GITHUB_TOKEN=$(gh auth token)"
  --artifact-server-path "$tmp/artifacts"
)
[[ -n "$job" ]] && args+=(-j "$job")
[[ -n "$arch" ]] && args+=(--matrix "arch:$arch")

log "act ${args[*]} ${extra[*]+${extra[*]}}"
act "${args[@]}" ${extra[@]+"${extra[@]}"}
