#!/usr/bin/env bash
# Deploy the image to minikube via the Helm chart, then run TestAPI through the Gateway. See docs/CI.md#minikube-e2e
set -euo pipefail

E2E_IMAGE="${E2E_IMAGE:-echo-pong:ci}"
PROFILE="${MINIKUBE_PROFILE:-echo-pong-e2e}"
K8S_VERSION="${K8S_VERSION:-}"
KEEP_CLUSTER="${KEEP_CLUSTER:-0}"
LOCAL_PORT="${LOCAL_PORT:-18080}"
root="$(cd "$(dirname "${BASH_SOURCE[0]}")/../../.." && pwd)"
CHART_REF="${CHART_REF:-$root/helm/echo-pong}"

NAMESPACE=echo-pong
RELEASE=echo-pong
AUTH_SECRET=echo-pong-auth
kc() { kubectl --context "$PROFILE" -n "$NAMESPACE" "$@"; }
log() { printf '==> %s\n' "$*"; }

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

log "start minikube ($PROFILE${K8S_VERSION:+, k8s v$K8S_VERSION})"
minikube start -p "$PROFILE" --driver=docker ${K8S_VERSION:+--kubernetes-version="v$K8S_VERSION"}

log "load $E2E_IMAGE"
minikube -p "$PROFILE" image load "$E2E_IMAGE"

chart="$CHART_REF"
if [[ -d "$chart" ]]; then
  log "helm dependency build $chart"
  helm dependency build "$chart"
fi

log "create namespace + auth secret"
kubectl --context "$PROFILE" create namespace "$NAMESPACE" --dry-run=client -o yaml | kubectl --context "$PROFILE" apply -f -
# Reuse the token on a kept cluster: the app reads the secret file only at startup.
token="$(kc get secret "$AUTH_SECRET" -o jsonpath='{.data.token}' 2>/dev/null | base64 -d || true)"
if [[ -z "$token" ]]; then
  token="$(od -An -N16 -tx1 /dev/urandom | tr -d ' \n')"
  kc create secret generic "$AUTH_SECRET" --from-literal=token="$token"
fi

log "helm upgrade --install"
helm upgrade --install "$RELEASE" "$chart" \
  --kube-context "$PROFILE" -n "$NAMESPACE" --wait --timeout 5m \
  --set image.repository="${E2E_IMAGE%:*}" \
  --set image.tag="${E2E_IMAGE##*:}" \
  --set image.pullPolicy=Never \
  --set auth.existingSecret="$AUTH_SECRET"

# Envoy proxy is created by the controller after install, so helm --wait doesn't cover it.
log "wait for Gateway Programmed"
kc wait --for=condition=Programmed "gateway/$RELEASE" --timeout=3m
envoy_svc="$(kc get svc -o name \
  -l "gateway.envoyproxy.io/owning-gateway-name=$RELEASE,gateway.envoyproxy.io/owning-gateway-namespace=$NAMESPACE")"
kc rollout status "deployment/${envoy_svc#service/}" --timeout=3m 2>/dev/null \
  || kc wait --for=condition=Ready pod -l "gateway.envoyproxy.io/owning-gateway-name=$RELEASE" --timeout=3m
gw_port="$(kc get "gateway/$RELEASE" -o jsonpath='{.spec.listeners[0].port}')"
log "port-forward $envoy_svc $LOCAL_PORT:$gw_port"
kc port-forward "$envoy_svc" "$LOCAL_PORT:$gw_port" >/dev/null 2>&1 &
pf_pid=$!

log "go test TestAPI through the Gateway"
cd "$root/src"
E2E_BASE_URL="http://127.0.0.1:$LOCAL_PORT" E2E_SECRET="$token" \
  go test -tags e2e -count=1 -v -run '^TestAPI$' ./test/e2e
