#!/usr/bin/env bash
# Deploy the image to minikube via the Helm chart, then run TestAPI against it. See docs/CI.md#minikube-e2e
set -euo pipefail

E2E_IMAGE="${E2E_IMAGE:-echo-pong:ci}"
PROFILE="${MINIKUBE_PROFILE:-echo-pong-e2e}"
K8S_VERSION="${K8S_VERSION:-}"
KEEP_CLUSTER="${KEEP_CLUSTER:-0}"
LOCAL_PORT="${LOCAL_PORT:-18080}"
owner="$(printf '%s' "${GITHUB_REPOSITORY_OWNER:-yoyobesser}" | tr '[:upper:]' '[:lower:]')"
CHART_REF="${CHART_REF:-oci://ghcr.io/$owner/charts/echo-pong}"

NAMESPACE=echo-pong
RELEASE=echo-pong
AUTH_SECRET=echo-pong-auth
root="$(cd "$(dirname "${BASH_SOURCE[0]}")/../../.." && pwd)"
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

# Latest released chart; in-repo chart until a release exists. See docs/CI.md#minikube-e2e
if helm show chart "$CHART_REF" >/dev/null 2>&1; then
  chart="$CHART_REF"
else
  chart="$root/helm/echo-pong"
  echo "::warning::no chart release at $CHART_REF, using in-repo $chart"
fi
log "chart $chart ($(helm show chart "$chart" 2>/dev/null | sed -n 's/^version: //p'))"

log "create namespace + auth secret"
kubectl --context "$PROFILE" create namespace "$NAMESPACE" --dry-run=client -o yaml | kubectl --context "$PROFILE" apply -f -
token="$(od -An -N16 -tx1 /dev/urandom | tr -d ' \n')"
kc create secret generic "$AUTH_SECRET" --from-literal=token="$token" --dry-run=client -o yaml | kc apply -f -

log "helm upgrade --install"
helm upgrade --install "$RELEASE" "$chart" \
  --kube-context "$PROFILE" -n "$NAMESPACE" --wait --timeout 5m \
  --set image.repository="${E2E_IMAGE%:*}" \
  --set image.tag="${E2E_IMAGE##*:}" \
  --set image.pullPolicy=Never \
  --set auth.existingSecret="$AUTH_SECRET"

svc_port="$(kc get svc "$RELEASE" -o jsonpath='{.spec.ports[0].port}')"
log "port-forward svc/$RELEASE $LOCAL_PORT:$svc_port"
kc port-forward "svc/$RELEASE" "$LOCAL_PORT:$svc_port" >/dev/null 2>&1 &
pf_pid=$!

log "go test TestAPI against live deploy"
cd "$root/src"
E2E_BASE_URL="http://127.0.0.1:$LOCAL_PORT" E2E_SECRET="$token" \
  go test -tags e2e -count=1 -v -run '^TestAPI$' ./test/e2e
