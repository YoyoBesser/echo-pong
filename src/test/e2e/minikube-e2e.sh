#!/usr/bin/env bash
# Deploy the image to minikube via the Helm chart, then run TestAPI through the Gateway. See docs/CI.md#minikube-e2e
set -euo pipefail

IMAGE="${E2E_IMAGE:-echo-pong:ci}"
PROFILE="${MINIKUBE_PROFILE:-echo-pong-e2e}"
K8S_VERSION="${K8S_VERSION:-}"
KEEP_CLUSTER="${KEEP_CLUSTER:-0}"
LOCAL_PORT="${LOCAL_PORT:-18080}"
root="$(cd "$(dirname "${BASH_SOURCE[0]}")/../../.." && pwd)"
CHART_REF="${CHART_REF:-$root/helm/echo-pong}"
NAMESPACE=echo-pong
RELEASE=echo-pong
AUTH_SECRET=echo-pong-auth
# shellcheck source=scripts/lib/minikube.sh
source "$root/scripts/lib/minikube.sh"

pf_pid=""
cleanup() {
  [[ -n "$pf_pid" ]] && kill "$pf_pid" 2>/dev/null || true
  if [[ "$KEEP_CLUSTER" == 1 ]]; then
    log "KEEP_CLUSTER=1: leaving minikube profile '$PROFILE' running"
  else
    minikube delete -p "$PROFILE" >/dev/null 2>&1 || true
  fi
}
trap cleanup EXIT

mk_start
mk_load_image
# shellcheck disable=SC2119  # no extra helm args
token="$(mk_deploy)"
mk_wait_gateway

envoy_svc="$(mk_envoy_svc)"
gw_port="$(kc get "gateway/$RELEASE" -o jsonpath='{.spec.listeners[0].port}')"
log "port-forward $envoy_svc $LOCAL_PORT:$gw_port"
kc port-forward "$envoy_svc" "$LOCAL_PORT:$gw_port" >/dev/null 2>&1 &
pf_pid=$!

log "go test TestAPI through the Gateway"
cd "$root/src"
E2E_BASE_URL="http://127.0.0.1:$LOCAL_PORT" E2E_SECRET="$token" \
  go test -tags e2e -count=1 -v -run '^TestAPI$' ./test/e2e
