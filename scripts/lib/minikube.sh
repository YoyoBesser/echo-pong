#!/usr/bin/env bash
# Shared minikube deploy steps for minikube-e2e.sh and minikube-up.sh. See docs/LOCAL-TESTING.md#minikube-up
# Callers set: PROFILE, NAMESPACE, RELEASE, AUTH_SECRET, CHART_REF, IMAGE; optional K8S_VERSION.

mk_root="$(cd "$(dirname "${BASH_SOURCE[0]}")/../.." && pwd)"

log() { printf '==> %s\n' "$*" >&2; }
kc() { kubectl --context "$PROFILE" -n "$NAMESPACE" "$@"; }

# k8s-version pin from install-ci-tools, so local clusters match CI.
mk_pinned_k8s_version() {
  sed -n 's/^ *k8s-version=\([0-9.]*\).*/\1/p' "$mk_root/.github/actions/install-ci-tools/action.yml"
}

mk_start() {
  log "start minikube ($PROFILE${K8S_VERSION:+, k8s v$K8S_VERSION})"
  minikube start -p "$PROFILE" --driver=docker ${K8S_VERSION:+--kubernetes-version="v$K8S_VERSION"}
}

mk_load_image() {
  log "load $IMAGE"
  minikube -p "$PROFILE" image load "$IMAGE"
}

# Namespace (PSA restricted) + auth Secret + helm install of $CHART_REF. Extra args go to helm. Prints the token.
mk_deploy() {
  if [[ -d "$CHART_REF" ]]; then
    log "helm dependency build $CHART_REF"
    helm dependency build "$CHART_REF" >&2
  fi

  log "create namespace (PSA restricted) + auth secret"
  kubectl --context "$PROFILE" create namespace "$NAMESPACE" --dry-run=client -o yaml | kubectl --context "$PROFILE" apply -f - >&2
  # API server rejects pods that drop the hardened securityContext. See docs/HELM.md#pod-security-admission
  kubectl --context "$PROFILE" label namespace "$NAMESPACE" --overwrite \
    pod-security.kubernetes.io/enforce=restricted pod-security.kubernetes.io/enforce-version=latest >&2
  # Reuse the token on a kept cluster: the app reads the secret file only at startup.
  local token
  token="$(kc get secret "$AUTH_SECRET" -o jsonpath='{.data.token}' 2>/dev/null | base64 -d || true)"
  if [[ -z "$token" ]]; then
    token="$(od -An -N16 -tx1 /dev/urandom | tr -d ' \n')"
    kc create secret generic "$AUTH_SECRET" --from-literal=token="$token" >&2
  fi

  log "helm upgrade --install"
  helm upgrade --install "$RELEASE" "$CHART_REF" \
    --kube-context "$PROFILE" -n "$NAMESPACE" --wait --timeout 5m \
    --set image.repository="${IMAGE%:*}" \
    --set image.tag="${IMAGE##*:}" \
    --set image.pullPolicy=Never \
    --set auth.existingSecret="$AUTH_SECRET" \
    "$@" >&2
  printf '%s\n' "$token"
}

# Envoy proxy Service the controller created for our Gateway.
mk_envoy_svc() {
  kc get svc -o name \
    -l "gateway.envoyproxy.io/owning-gateway-name=$RELEASE,gateway.envoyproxy.io/owning-gateway-namespace=$NAMESPACE"
}

# Envoy proxy is created by the controller after install, so helm --wait doesn't cover it.
mk_wait_gateway() {
  log "wait for Gateway Programmed"
  kc wait --for=condition=Programmed "gateway/$RELEASE" --timeout=3m >&2
  local svc
  svc="$(mk_envoy_svc)"
  kc rollout status "deployment/${svc#service/}" --timeout=3m >&2 2>/dev/null \
    || kc wait --for=condition=Ready pod -l "gateway.envoyproxy.io/owning-gateway-name=$RELEASE" --timeout=3m >&2
}

# Poll $1/ping (token $2) every 100ms during a rolling restart; fail on any non-200. See docs/CI.md#rollout-verification
mk_rollout_check() {
  local url="$1" token="$2" codes poller total bad
  codes="$(mktemp)"
  (
    while :; do
      curl -s -o /dev/null -w '%{http_code}\n' --max-time 2 -H "Authorization: Bearer $token" "$url/ping" >>"$codes" || true
      sleep 0.1
    done
  ) &
  poller=$!
  sleep 2
  log "rolling restart of deployment/$RELEASE under load"
  kc rollout restart "deployment/$RELEASE" >&2
  kc rollout status "deployment/$RELEASE" --timeout=5m >&2
  sleep 5 # old pods finish terminating
  kill "$poller" 2>/dev/null || true
  wait "$poller" 2>/dev/null || true
  # Snapshot once: a curl still in flight may append after the poller is killed.
  local snapshot
  snapshot="$(cat "$codes")"
  rm -f "$codes"
  total="$(grep -c . <<<"$snapshot" || true)"
  bad="$(grep -cv '^200$' <<<"$snapshot" || true)"
  log "rollout check: $total requests, $bad not 200 ($(sort <<<"$snapshot" | uniq -c | tr -s ' ' | tr '\n' ','))"
  [[ "$total" -gt 0 && "$bad" -eq 0 ]]
}
