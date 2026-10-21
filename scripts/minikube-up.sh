#!/usr/bin/env bash
# Run the app on a local minikube behind Envoy Gateway + minikube tunnel. See docs/LOCAL-TESTING.md#minikube-up
set -euo pipefail

usage() {
  cat <<'USAGE'
usage: scripts/minikube-up.sh [--tag <ghcr-tag>] [--port <port>] [--test] | --status | --down

  (default)    build the image from src/ for this machine's arch
  --tag TAG    use ghcr.io/yoyobesser/echo-pong:TAG instead (needs `docker login ghcr.io` if private)
  --port PORT  Gateway listener port on 127.0.0.1 (default 8080; ports < 1024 make minikube tunnel ask for sudo)
  --test       after deploying, run all e2e suites (container, static binary, live Gateway) and exit with the result
  --status     show what's running (cluster, release, pods, tunnel) and the connection info; no changes
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

# URL, token and ready-to-paste curls. $1 url, $2 token, $3 image, $4 k8s version, $5 footer.
print_info() {
  cat <<INFO

echo-pong is up behind Envoy Gateway ($3, k8s $4, profile $PROFILE)

  URL     $1
  Token   $2

  curl $1/health
  curl -H "Authorization: Bearer $2" $1/ping
  curl -H "Authorization: $2" $1/pong
  curl -i $1/ping                       # 401 without a token
  open $1/                              # API docs page

  kubectl --context $PROFILE -n $NAMESPACE get gateway,svc,pods

$5
INFO
}

# What's running, without changing anything. Exit 0 only if the app answers through the tunnel.
status() {
  local ok=1
  line() { printf '  %-9s %s\n' "$1" "$2"; }
  echo "minikube-up status (profile $PROFILE)"
  if ! minikube status -p "$PROFILE" >/dev/null 2>&1; then
    line cluster "not running (start: scripts/minikube-up.sh)"
    return 1
  fi
  local k8s image ready tunnel ip port token url
  k8s="$(kubectl --context "$PROFILE" get nodes -o jsonpath='{.items[0].status.nodeInfo.kubeletVersion}')"
  line cluster "running, k8s $k8s"
  image="$(kc get deploy "$RELEASE" -o jsonpath='{.spec.template.spec.containers[0].image}' 2>/dev/null || true)"
  if [[ -z "$image" ]]; then
    line release "not deployed (deploy: scripts/minikube-up.sh)"
    return 1
  fi
  ready="$(kc get deploy "$RELEASE" -o jsonpath='{.status.readyReplicas}/{.spec.replicas}')"
  line release "$RELEASE, image $image"
  line pods "$ready ready"
  [[ "${ready%/*}" == "${ready#*/}" ]] || ok=0
  tunnel="$(pgrep -f "minikube tunnel -p $PROFILE" | head -1 || true)"
  ip="$(kc get "$(mk_envoy_svc)" -o jsonpath='{.status.loadBalancer.ingress[0].ip}' 2>/dev/null || true)"
  port="$(kc get "gateway/$RELEASE" -o jsonpath='{.spec.listeners[0].port}')"
  token="$(kc get secret "$AUTH_SECRET" -o jsonpath='{.data.token}' | base64 -d)"
  url="http://${ip:-127.0.0.1}:$port"
  if [[ -n "$tunnel" && -n "$ip" ]]; then
    line tunnel "running (pid $tunnel), Gateway address $ip"
  else
    line tunnel "not running: URL unreachable until you rerun scripts/minikube-up.sh"
    ok=0
  fi
  if curl -fsS --max-time 3 "$url/health" >/dev/null 2>&1; then line health "$url/health OK"; else line health "no answer from $url"; ok=0; fi
  print_info "$url" "$token" "$image" "$k8s" "scripts/minikube-up.sh --down deletes the cluster."
  [[ "$ok" == 1 ]]
}
while (($#)); do
  case "$1" in
    -h | --help) usage; exit 0 ;;
    --tag) tag="${2:?--tag needs a value}"; shift ;;
    --port) port="${2:?--port needs a value}"; shift ;;
    --test) test=1 ;;
    --status) status; exit ;;
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
token="$(mk_deploy -f "$CHART_REF/values-local.yaml" --set gateway.port="$port")"

log "minikube tunnel (Ctrl-C to stop)"
tunnel_log="$(mktemp)"
# Own process group (set -m): on shutdown minikube tunnel signals its group, which would kill this script.
set -m
minikube tunnel -p "$PROFILE" --cleanup >"$tunnel_log" 2>&1 &
tunnel_pid=$!
set +m
# wait returns 143 for the killed tunnel; || true keeps set -e from turning that into our exit code.
trap 'rc=$?; kill "$tunnel_pid" 2>/dev/null || true; wait "$tunnel_pid" 2>/dev/null || true; rm -f "$tunnel_log"; exit "$rc"' EXIT

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

print_info "$url" "$token" "$IMAGE" "v$K8S_VERSION" "Ctrl-C stops the tunnel. scripts/minikube-up.sh --down deletes the cluster."

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

  arch="$(docker image inspect --format '{{.Architecture}}' "$IMAGE")"
  bin_dir="$(mktemp -d)"
  E2E_IMAGE="$IMAGE" suite "CLI e2e" e2e -run '^TestCLI$'
  E2E_IMAGE="$IMAGE" suite "API e2e (container)" e2e -run '^TestAPI$'
  suite "static binary ($arch)" "$root/.github/scripts/extract-binary.sh" "$IMAGE" "$arch" "$bin_dir"
  E2E_BASE_URL="$url" E2E_SECRET="$token" suite "API e2e (live Gateway, $url)" e2e -run '^TestAPI$'
  suite "zero-downtime rollout" mk_rollout_check "$url" "$token"
  rm -rf "$bin_dir"

  printf '\nTest results (%s)\n' "$IMAGE"
  printf '  %s\n' "${results[@]}"
  exit "$rc"
fi
wait "$tunnel_pid"
