# Helm

Chart: [`helm/echo-pong`](../helm/echo-pong). It's deliberately minimal for now: Deployment, Service, the Gateway API objects, and the Envoy Gateway subchart. Hardening to the [kube-linter policy](CI.md#kube-linter-policy) comes next.

| Value | Default | Purpose |
|---|---|---|
| `replicaCount` | `2` | Pods behind the Service |
| `image.repository` / `image.tag` | `ghcr.io/yoyobesser/echo-pong` / `appVersion` | App image |
| `image.pullPolicy` | `IfNotPresent` | `Never` in [minikube e2e](CI.md#minikube-e2e) (preloaded image) |
| `auth.existingSecret` | `echo-pong-auth` | See [Auth secret](#auth-secret) |
| `service.port` | `80` | Service port (container listens on `8080`) |
| `gateway.className` | `echo-pong` | GatewayClass created by the chart |
| `gateway.serviceType` | `ClusterIP` | Envoy proxy Service type, see [Envoy Gateway](#envoy-gateway) |
| `gateway.port` / `gateway.hostnames` | `80` / `[]` | Listener port; HTTPRoute hostnames (empty matches all) |
| `envoy-gateway.enabled` | `true` | Install the Envoy Gateway subchart |

## Envoy Gateway

Ingress uses the [Gateway API](https://gateway-api.sigs.k8s.io/), with [Envoy Gateway](https://gateway.envoyproxy.io/) as the implementation. The `gateway-helm` chart (v1.9.2, `oci://docker.io/envoyproxy`) is a dependency aliased `envoy-gateway`. It brings the Gateway API and Envoy CRDs (from its `crds/`, which Helm installs first) and the controller. The alias must be lowercase, because it ends up in resource names (`echo-pong-envoy-gateway-certgen`).

The chart then defines:

- `GatewayClass` `echo-pong`, owned by `gateway.envoyproxy.io/gatewayclass-controller`.
- `EnvoyProxy`, referenced from the Gateway's `infrastructure.parametersRef`. It sets the proxy Service type.
- `Gateway`, with one HTTP listener on `gateway.port`.
- `HTTPRoute`, sending everything to the app Service.

`gateway.serviceType` defaults to `ClusterIP`. Nothing is exposed directly (README L58), and the Gateway reports `Programmed` on clusters without a load balancer, such as minikube. With `LoadBalancer`, minikube leaves the address `<pending>` and the Gateway never becomes `Programmed`. On a cloud cluster (EKS), set `LoadBalancer` to get an NLB in front of Envoy.

Envoy Gateway's controller is cluster-scoped (GatewayClass, CRDs). Installing it per app release is fine for a single-app cluster and for e2e. A shared cluster would install it once, separately, with `envoy-gateway.enabled=false` here.

## Auth secret

The app reads its token from a file (`SECRET_FILE_PATH`). The chart mounts Secret `auth.existingSecret` (key `token`) read-only at `/var/run/secrets/echo-pong/` and points `SECRET_FILE_PATH` at it. The chart never creates the Secret, so no token lives in the repo or in values (README L52). Create it out-of-band, for example:

```sh
kubectl -n echo-pong create secret generic echo-pong-auth --from-literal=token="$(openssl rand -hex 16)"
```

The app reads the file once at startup, so pods need a restart (`kubectl rollout restart`) after rotating the token.

## Probes

The app sleeps 10s before it listens (README L32). The `startupProbe` allows 15 × 2s = 30s before failing, and readiness/liveness only start after it succeeds. This keeps a slow start from being killed by liveness, and pods only join the Service once `/health` answers.
