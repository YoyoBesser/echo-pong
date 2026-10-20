#!/usr/bin/env bash
# Run the app on a local minikube behind Envoy Gateway + minikube tunnel. See docs/LOCAL-TESTING.md#minikube-up
set -euo pipefail

usage() {
  cat <<'USAGE'
usage: scripts/minikube-up.sh [--tag <ghcr-tag>] [--port <port>] [--test] [--down]

  (default)    build the image from src/ for this machine's arch
  --tag TAG    use ghcr.io/yoyobesser/echo-pong:TAG instead (needs `docker login ghcr.io` if private)
  --port PORT  Gateway listener port on 127.0.0.1 (default 8080; ports < 1024 make minikube tunnel ask for sudo)
  --test       after deploying, run all e2e suites (container, binary, live Gateway) and exit with the result
  --down       delete the minikube profile and exit

Deploys the local chart (helm/echo-pong), runs `minikube tunnel` in the foreground, prints connection
info. Ctrl-C stops the tunnel; the cluster keeps running (rerun to reconnect, --down to delete).
env: MINIKUBE_PROFILE (default echo-pong-dev), K8S_VERSION (default: CI pin)
USAGE
}

root="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
# shellcheck source=scripts/lib/minikube.sh
source "$root/scripts/lib/minikube.sh"

PROFILE="${MINIKUBE_PROFILE:-echo-pong-dev}"
NAMESPACE=echo-pong
RELEASE=echo-pong
AUTH_SECRET=echo-pong-auth
CHART_REF="$root/helm/echo-pong"
tag="" port=8080 test=0
while (($#)); do
  case "$1" in
    -h | --help) usage; exit 0 ;;
    --tag) tag="${2:?--tag needs a value}"; shift ;;
    --port) port="${2:?--port needs a value}"; shift ;;
    --test) test=1 ;;
    --down) minikube delete -p "$PROFILE"; exit 0 ;;
    *) echo "unknown arg: $1" >&2; usage >&2; exit 2 ;;
  esac
  shift
done
for bin in docker minikube kubectl helm curl; do command -v "$bin" >/dev/null || { echo "missing: $bin" >&2; exit 2; }; done
K8S_VERSION="${K8S_VERSION:-$(mk_pinned_k8s_version)}"

if [[ -n "$tag" ]]; then
  IMAGE="ghcr.io/yoyobesser/echo-pong:$tag"
  log "pull $IMAGE"
  docker pull --quiet "$IMAGE" >/dev/null || {
    echo "pull failed; if the package is private: gh auth token | docker login ghcr.io -u <user> --password-stdin" >&2
    echo "(the token needs the read:packages scope: gh auth refresh -s read:packages)" >&2
    exit 1
  }
else
  IMAGE="echo-pong:dev-$(git -C "$root" rev-parse --short HEAD)$(git -C "$root" diff --quiet || echo -dirty)"
  log "build $IMAGE from src/"
  docker buildx build --quiet --load -t "$IMAGE" "$root/src" >/dev/null
fi

mk_start
mk_load_image
token="$(mk_deploy --set gateway.serviceType=LoadBalancer --set gateway.port="$port")"

log "minikube tunnel (Ctrl-C to stop)"
tunnel_log="$(mktemp)"
minikube tunnel -p "$PROFILE" --cleanup >"$tunnel_log" 2>&1 &
tunnel_pid=$!
trap 'kill "$tunnel_pid" 2>/dev/null; wait "$tunnel_pid" 2>/dev/null; rm -f "$tunnel_log"' EXIT

mk_wait_gateway
svc="$(mk_envoy_svc)"
ip=""
for _ in $(seq 60); do
  ip="$(kc get "$svc" -o jsonpath='{.status.loadBalancer.ingress[0].ip}')"
  [[ -n "$ip" ]] && break
  sleep 1
done
[[ -n "$ip" ]] || { echo "no external IP from minikube tunnel:" >&2; cat "$tunnel_log" >&2; exit 1; }
url="http://$ip:$port"
for _ in $(seq 30); do curl -fsS "$url/health" >/dev/null 2>&1 && break; sleep 1; done

cat <<INFO

echo-pong is up behind Envoy Gateway ($IMAGE, k8s v$K8S_VERSION, profile $PROFILE)

  URL     $url
  Token   $token

  curl $url/health
  curl -H "Authorization: Bearer $token" $url/ping
  curl -H "Authorization: $token" $url/pong
  curl -i $url/ping                       # 401 without a token
  open $url/                              # API docs page

  kubectl --context $PROFILE -n $NAMESPACE get gateway,svc,pods

Ctrl-C stops the tunnel. scripts/minikube-up.sh --down deletes the cluster.
INFO

if [[ "$test" == 1 ]]; then
  # Same suites as CI's e2e-tests job, local arch only. See docs/LOCAL-TESTING.md#minikube-up
  command -v go >/dev/null || { echo "missing: go" >&2; exit 2; }
  results=() rc=0
  suite() {
    local name="$1"; shift
    log "test: $name"
    if "$@" >&2; then results+=("✅ $name"); else results+=("❌ $name"); rc=1; fi
  }
  # shellcheck disable=SC2329  # called via suite
  e2e() { go test -C "$root/src" -tags e2e -count=1 "$@" ./test/e2e; }
  # shellcheck disable=SC2329  # called via suite
  binary_on() {
    docker build --quiet -f "$root/src/test/e2e/binary.Dockerfile" --build-arg "BASE=$1:latest" \
      -t "echo-pong:bin-$1" "$bin_dir" >/dev/null && E2E_IMAGE="echo-pong:bin-$1" e2e -run '^Test(CLI|API)$'
  }

  arch="$(docker image inspect --format '{{.Architecture}}' "$IMAGE")"
  bin_dir="$(mktemp -d)"
  E2E_IMAGE="$IMAGE" suite "CLI e2e" e2e -run '^TestCLI$'
  E2E_IMAGE="$IMAGE" suite "API e2e (container)" e2e -run '^TestAPI$'
  suite "static binary ($arch)" "$root/.github/scripts/extract-binary.sh" "$IMAGE" "$arch" "$bin_dir"
  suite "binary e2e (ubuntu)" binary_on ubuntu
  suite "binary e2e (alpine)" binary_on alpine
  E2E_BASE_URL="$url" E2E_SECRET="$token" suite "API e2e (live Gateway, $url)" e2e -run '^TestAPI$'
  rm -rf "$bin_dir"

  printf '\nTest results (%s)\n' "$IMAGE"
  printf '  %s\n' "${results[@]}"
  exit "$rc"
fi
wait "$tunnel_pid"
