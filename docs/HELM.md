# Helm

Chart: [`helm/echo-pong`](../helm/echo-pong): Deployment, Service, ServiceAccount, PDB, NetworkPolicy, optional HPA, the Gateway API objects, and the Envoy Gateway subchart, plus [local values](#local-values) for minikube. It passes the [kube-linter policy](CI.md#kube-linter-policy).

| Value | Default | Purpose |
|---|---|---|
| `replicaCount` | `2` | Pods behind the Service (ignored when autoscaling) |
| `autoscaling.*` | off; min 2, max 6, 70% CPU | See [Autoscaling](#autoscaling) |
| `imagePullSecrets` | `[]` | See [Image pull](#image-pull) |
| `rollout.strategy`, `pdb.*`, `antiAffinity.enabled` | RollingUpdate 0/1, PDB `minAvailable: 1`, on | See [Zero downtime](#zero-downtime) |
| `preStopSleepSeconds`, `terminationGracePeriodSeconds` | `5`, `30` | See [Zero downtime](#zero-downtime) |
| `preferredArch` | `arm64` | See [Scheduling](#scheduling) |
| `resources` | requests 50m / 32Mi, limit 64Mi | See [Resources](#resources) |
| `networkPolicy.enabled` | `true` | See [Network policy](#network-policy) |
| `image.repository` / `image.tag` | `ghcr.io/yoyobesser/echo-pong` / `appVersion` | App image |
| `image.pullPolicy` | `IfNotPresent` | `Never` in [minikube e2e](CI.md#minikube-e2e) (preloaded image) |
| `auth.existingSecret` | `echo-pong-auth` | See [Auth secret](#auth-secret) |
| `podSecurityContext` / `securityContext` | see [Security context](#security-context) | Pod / container security context |
| `service.port` | `80` | Service port (container listens on `8080`) |
| `gateway.className` | `echo-pong` | GatewayClass created by the chart |
| `gateway.serviceType` | `ClusterIP` | Envoy proxy Service type, see [Envoy Gateway](#envoy-gateway) |
| `gateway.port` / `gateway.hostnames` | `80` / `[]` | Listener port; HTTPRoute hostnames (empty matches all) |
| `envoy-gateway.enabled` | `true` | Install the Envoy Gateway subchart |

## Contents

- [Envoy Gateway](#envoy-gateway)
- [Security context](#security-context)
- [Pod Security Admission](#pod-security-admission)
- [Zero downtime](#zero-downtime)
- [Autoscaling](#autoscaling)
- [Local values](#local-values)
- [Image pull](#image-pull)
- [Scheduling](#scheduling)
- [Resources](#resources)
- [Network policy](#network-policy)
- [Auth secret](#auth-secret)
- [Probes](#probes)

## Envoy Gateway

Ingress uses the [Gateway API](https://gateway-api.sigs.k8s.io/), with [Envoy Gateway](https://gateway.envoyproxy.io/) as the implementation. The `gateway-helm` chart (v1.9.2, `oci://docker.io/envoyproxy`) is a dependency aliased `envoy-gateway`. It brings the Gateway API and Envoy CRDs (from its `crds/`, which Helm installs first) and the controller. The alias must be lowercase, because it ends up in resource names (`echo-pong-envoy-gateway-certgen`).

The chart then defines:

- `GatewayClass` `echo-pong`, owned by `gateway.envoyproxy.io/gatewayclass-controller`.
- `EnvoyProxy`, referenced from the Gateway's `infrastructure.parametersRef`. It sets the proxy Service type.
- `Gateway`, with one HTTP listener on `gateway.port`.
- `HTTPRoute`, sending everything to the app Service.

`gateway.serviceType` defaults to `ClusterIP`. Nothing is exposed directly (README L58), and the Gateway reports `Programmed` on clusters without a load balancer, such as minikube. With `LoadBalancer`, minikube leaves the address `<pending>` and the Gateway never becomes `Programmed`. On a cloud cluster (EKS), set `LoadBalancer` to get an NLB in front of Envoy.

Envoy Gateway's controller is cluster-scoped (GatewayClass, CRDs). Installing it per app release is fine for a single-app cluster and for e2e. A shared cluster would install it once, separately, with `envoy-gateway.enabled=false` here.

## Security context

The pod and container run locked down by default (`podSecurityContext`, `securityContext` in `values.yaml`):

| Setting | Value | README |
|---|---|---|
| `runAsNonRoot`, `runAsUser`/`runAsGroup`/`fsGroup` | `true`, `65532` (the image's numeric `USER`, see [CONTAINER.md#non-root](CONTAINER.md#non-root)) | L49 |
| `allowPrivilegeEscalation`, `privileged` | `false` | L49 |
| `readOnlyRootFilesystem` | `true`. The app writes nothing, and its secret is a read-only volume | L53 |
| `capabilities.drop` | `[ALL]` | L83 |
| `seccompProfile.type` | `RuntimeDefault` | L83 |

Removing or weakening these fails a PR in one of two places:

1. **Helm CI (static):** kube-linter's `run-as-non-root` and `no-read-only-root-fs` fail when those fields are missing or unsafe. Its privileged/escalation checks only fire when the field is set to an unsafe value ([CI.md#kube-linter-policy](CI.md#kube-linter-policy)).
2. **App CI e2e (deploy time):** [Pod Security Admission](#pod-security-admission) `restricted` on the e2e namespace refuses pods missing `allowPrivilegeEscalation: false`, drop `ALL`, seccomp or non-root, so the minikube e2e fails.

## Pod Security Admission

The [minikube e2e](CI.md#minikube-e2e) labels its namespace `pod-security.kubernetes.io/enforce=restricted` (with `enforce-version=latest`) before installing. Kubernetes' built-in admission then rejects any pod that isn't non-root, without privilege escalation, with capabilities dropped to `ALL` and seccomp `RuntimeDefault`. If the chart's [security context](#security-context) regresses, the pods never start and the e2e fails. A bare pod with no securityContext is refused with `violates PodSecurity "restricted:latest"`.

Everything in the release runs under `restricted`: the app and the Envoy Gateway controller, certgen job and proxy. PSA doesn't check `readOnlyRootFilesystem`; kube-linter's `no-read-only-root-fs` covers that.

This is enforced only on the e2e namespace. The chart doesn't create its namespace, so it can't set the label itself. On a real cluster, the platform has to label app namespaces the same way.

## Zero downtime

README L56: "Zero-downtime deployments server must be available and ready at all times."

| Value | Default | Why |
|---|---|---|
| `rollout.strategy` | `RollingUpdate`, `maxUnavailable: 0`, `maxSurge: 1` | A new pod must be Ready before an old one goes away, so serving capacity never drops below `replicaCount` during `helm upgrade` |
| `pdb.enabled`, `pdb.minAvailable` | `true`, `1` | Node drains and cluster upgrades can't evict the last serving pod |
| `antiAffinity.enabled` | `true` | Preferred pod anti-affinity on `kubernetes.io/hostname`: replicas spread across nodes when there are several, so one node failure doesn't take both |

A pod is stopped in this order:

1. **`preStop` sleep** (`preStopSleepSeconds: 5`). The pod keeps serving while its endpoint is removed from the Service and Envoy stops routing to it. It's a native Kubernetes `sleep` action, so the image needs no shell.
2. **SIGTERM drain.** The app stops accepting connections and finishes in-flight requests (`http.Server.Shutdown`, up to 20s), then exits 0.
3. **Grace period.** `terminationGracePeriodSeconds: 30` covers both steps before the kubelet would SIGKILL.

Together with 2 replicas and the startup/readiness gates ([Probes](#probes)), this keeps serving pods behind the Gateway through a rolling update. [CI.md#rollout-verification](CI.md#rollout-verification) checks a rolling restart on every PR, on a single-node minikube; node drains and multi-node clusters aren't tested.

## Autoscaling

`autoscaling.enabled` adds a HorizontalPodAutoscaler (`autoscaling/v2`) on CPU utilization (`targetCPUUtilizationPercentage: 70`), between `minReplicas` and `maxReplicas`. With autoscaling on, the Deployment leaves out `replicas`, so `helm upgrade` doesn't reset what the HPA chose.

kube-linter's `minimum-two-replicas` would then flag the Deployment, so it carries an exception annotation. The floor is still enforced on the HPA by `hpa-minimum-two-replicas` and on the PDB by `pdb-min-available`: rendering with `minReplicas: 1` fails both.

It's off by default because an HPA needs metrics-server, which a bare minikube doesn't run. Turn it on (`--set autoscaling.enabled=true`) on a cluster that has metrics-server, e.g. EKS with its metrics-server add-on.

## Local values

The base `values.yaml` holds secure, cluster-agnostic defaults. [`values-local.yaml`](../helm/echo-pong/values-local.yaml) overrides only what [`scripts/minikube-up.sh`](LOCAL-TESTING.md#minikube-up) needs: Envoy as a `LoadBalancer` on port 8080 for `minikube tunnel`, and `pullPolicy: Never`, because the image is loaded into minikube rather than pulled. The CI minikube e2e uses the base values (ClusterIP + port-forward).

Helm CI lints, renders, schema-checks, policy-checks and trivy-gates both the base values and `values-local.yaml` ([CI.md#chart-lint](CI.md#chart-lint)).

## Image pull

README L59: "Cluster can pull from registry." Images are in GHCR, and the package is public, so a cluster can pull without credentials (an anonymous manifest fetch returns 200). If the package were private, it would need a `kubernetes.io/dockerconfigjson` Secret in the namespace, listed in `imagePullSecrets`:

```sh
kubectl -n echo-pong create secret docker-registry ghcr-pull \
  --docker-server=ghcr.io --docker-username=<user> --docker-password=<token with read:packages>
helm upgrade --install echo-pong helm/echo-pong --set 'imagePullSecrets[0].name=ghcr-pull'
```

Not tested: no cluster here ever pulls the image. The minikube flows load it into the cluster (`pullPolicy: Never`). On EKS, either make the package public or mirror it to ECR and pull with the node role. That second option is also how teams worldwide get fast pulls (see [EXPLAIN.md](EXPLAIN.md)).

## Scheduling

README L57: "ARM64 architecture preferred." The pod has a **preferred** (not required) node affinity for `kubernetes.io/arch: arm64` (`preferredArch`). It lands on arm64 nodes when the cluster has them, and still schedules on amd64 otherwise. The image is multi-arch, so either works. Set `preferredArch: ""` to drop the preference.

## Resources

Requests `cpu: 50m`, `memory: 32Mi` and a `memory: 64Mi` limit (`resources`). The app is a small Go HTTP server. Requests let the scheduler place it, and an HPA can scale on them later. The memory limit caps a leak. There's no CPU limit, so the pod isn't throttled while it has spare node CPU. Tune from real usage.

## Network policy

README L58: "No direct internet access (use ingress/proxy)." A NetworkPolicy (`networkPolicy.enabled`) allows ingress to the app pods only from the Envoy proxy pods of this release's Gateway. It selects them by `gateway.envoyproxy.io/owning-gateway-name` and `-namespace` labels, on the `http` port. Everything else is denied, including other pods in the cluster. Egress isn't restricted.

minikube's default CNI (kindnet) enforces it. A pod in another namespace can't reach `echo-pong.echo-pong.svc`, while the live-Gateway e2e still passes. On EKS, it needs a policy-enforcing CNI (VPC CNI with network policy enabled, or Calico).

The pod also runs under a dedicated ServiceAccount with `automountServiceAccountToken: false`: the app never talks to the Kubernetes API.

## Auth secret

The app reads its token from a file (`SECRET_FILE_PATH`). kube-linter's `env-var-secret` check flags that variable because of its name. It's annotated as an exception on the Deployment: the value is a path, and the app requires that name. The chart mounts Secret `auth.existingSecret` (key `token`) read-only at `/var/run/secrets/echo-pong/` and points `SECRET_FILE_PATH` at it. The chart never creates the Secret, so no token lives in the repo or in values (README L52). Create it out-of-band, for example:

```sh
kubectl -n echo-pong create secret generic echo-pong-auth --from-literal=token="$(openssl rand -hex 16)"
```

The app reads the file once at startup, so pods need a restart (`kubectl rollout restart`) after rotating the token.

## Probes

The app sleeps 10s before it listens (README L32). The `startupProbe` allows 15 × 2s = 30s before failing, and readiness/liveness only start after it succeeds. This keeps a slow start from being killed by liveness, and pods only join the Service once `/health` answers.
