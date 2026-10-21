#!/usr/bin/env bash
# Zero-downtime check on a cluster left by minikube-e2e.sh (KEEP_CLUSTER=1). See docs/CI.md#rollout-verification
set -euo pipefail

PROFILE="${MINIKUBE_PROFILE:-echo-pong-e2e}"
LOCAL_PORT="${LOCAL_PORT:-18081}"
root="$(cd "$(dirname "${BASH_SOURCE[0]}")/../../.." && pwd)"
NAMESPACE=echo-pong
RELEASE=echo-pong
AUTH_SECRET=echo-pong-auth
# shellcheck source=scripts/lib/minikube.sh
source "$root/scripts/lib/minikube.sh"

token="$(kc get secret "$AUTH_SECRET" -o jsonpath='{.data.token}' | base64 -d)"
svc="$(mk_envoy_svc)"
gw_port="$(kc get "gateway/$RELEASE" -o jsonpath='{.spec.listeners[0].port}')"
kc port-forward "$svc" "$LOCAL_PORT:$gw_port" >/dev/null 2>&1 &
pf_pid=$!
trap 'kill "$pf_pid" 2>/dev/null || true' EXIT
for _ in $(seq 30); do curl -fsS "http://127.0.0.1:$LOCAL_PORT/health" >/dev/null 2>&1 && break; sleep 1; done

mk_rollout_check "http://127.0.0.1:$LOCAL_PORT" "$token"
