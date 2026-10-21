# Explain

Answers to the README's "You will be asked to explain the following" ([L107](../README.md?plain=1#L107)). Short answers, with links to the reference docs for depth. Status: what's built today, and what's planned. Requirement tracking lives in [TASKS.md](TASKS.md).

## Contents

- [Deployment strategy](#deployment-strategy)
- [Scaling strategy](#scaling-strategy)
- [Security measures](#security-measures)
- [CI/CD pipeline](#cicd-pipeline)
- [Multi-architecture builds](#multi-architecture-builds)
- [Versioning and tagging strategy](#versioning-and-tagging-strategy)
- [Going cloud with EKS](#going-cloud-with-eks)
- [Fast global image pulls with AWS](#fast-global-image-pulls-with-aws)
- [Managing older and stale versions](#managing-older-and-stale-versions)

## Deployment strategy

[L108](../README.md?plain=1#L108). Helm chart [`helm/echo-pong`](../helm/echo-pong) deploys the app as a Deployment behind a ClusterIP Service. Traffic enters only through Envoy Gateway (Gateway API).

- **Packaging:** a Helm chart, not raw `k8s/` YAML. One values file drives image tag, security context, gateway type and rollout settings. Envoy Gateway ships as a pinned subchart ([HELM.md#envoy-gateway](HELM.md#envoy-gateway)).
- **Rollout:** `RollingUpdate` with `maxUnavailable: 0`, `maxSurge: 1`. A new pod must be Ready before an old one goes. 2 replicas minimum ([HELM.md#zero-downtime](HELM.md#zero-downtime)).
- **Readiness:** the app sleeps 10s before it listens. `startupProbe` gives it 30s. Readiness gates Service traffic on `/health` ([HELM.md#probes](HELM.md#probes)).
- **Availability:** PDB `minAvailable: 1` survives node drains. Preferred pod anti-affinity spreads replicas across nodes.
- **Ingress:** Envoy proxy Service is `ClusterIP` by default. Nothing is exposed directly. On EKS, set `gateway.serviceType=LoadBalancer` to get an NLB.
- **Proof:** CI deploys the chart to minikube on amd64 and arm64 and tests through the Gateway ([CI.md#minikube-e2e](CI.md#minikube-e2e)).
- **Shutdown:** a `preStop` sleep keeps the pod serving while Envoy drops its endpoint, then SIGTERM drains in-flight requests before exit ([HELM.md#zero-downtime](HELM.md#zero-downtime)).
- **Proven:** every PR polls `/ping` through the Gateway during a rolling restart and fails on any non-200 ([CI.md#rollout-verification](CI.md#rollout-verification)). With the protections turned off, it catches a 503.

## Scaling strategy

[L109](../README.md?plain=1#L109). Scale horizontally. The app is stateless: the token is read from a file, there's no session or storage. Any pod serves any request.

- **Floor:** 2 replicas, enforced by a custom kube-linter check ([CI.md#kube-linter-policy](CI.md#kube-linter-policy)). Two pods plus a PDB keep one serving through a rollout or a node drain.
- **Requests/limits:** set (50m CPU, 32Mi/64Mi memory). The scheduler packs pods correctly, and the HPA has a baseline to compute utilisation against.
- **Pods:** the chart has a HorizontalPodAutoscaler on CPU (`autoscaling.enabled`, `minReplicas: 2`), off by default because it needs metrics-server. When it's on, the HPA owns the replica count, and kube-linter still pins its floor at 2 ([HELM.md#autoscaling](HELM.md#autoscaling)).
- **Nodes (cloud):** on EKS, Karpenter (or Cluster Autoscaler) adds nodes when pods are pending. Prefer Graviton (arm64) nodes, which are cheaper per request. The chart already prefers `kubernetes.io/arch: arm64`, with fallback to any arch.
- **Ingress:** Envoy scales on its own (its own replicas, behind the NLB). Separate from the app.
- **Startup cost:** each new pod takes ~10s to become Ready. Scale on early signals, and keep headroom (the floor of 2) instead of scaling from 1.

## Security measures

[L110](../README.md?plain=1#L110). Defence in layers: minimal image, locked-down pod, network isolation, no secrets in repo, and scans that block release.

- **Image:** distroless `static` base, static Go binary, no package manager ([CONTAINER.md#base-image](CONTAINER.md#base-image)). Runs as numeric UID `65532`, so `runAsNonRoot` can verify it ([CONTAINER.md#non-root](CONTAINER.md#non-root)). `.dockerignore` allowlists only `go.mod` and `*.go`. Trade-off: a busybox shell is included for debugging ([CONTAINER.md#busybox](CONTAINER.md#busybox)).
- **Pod:** non-root, no privilege escalation, `readOnlyRootFilesystem`, drop `ALL` capabilities, seccomp `RuntimeDefault` ([HELM.md#security-context](HELM.md#security-context)). Dedicated ServiceAccount with no token mounted.
- **Pinned twice:** the `trivy config` gate fails CI if any setting is removed ([CI.md#trivy-config](CI.md#trivy-config)). The e2e namespace enforces Pod Security Admission `restricted`, so the API server refuses a regressed pod ([HELM.md#pod-security-admission](HELM.md#pod-security-admission)).
- **Network:** no direct internet access. Only Envoy reaches the app (ClusterIP Services, and a NetworkPolicy allowing only Envoy pods).
- **Secrets:** the token lives in an out-of-band Kubernetes Secret, mounted read-only. Never in values or repo ([HELM.md#auth-secret](HELM.md#auth-secret)). trivy fs and gitleaks scan the working tree and full git history on every commit ([CI.md#repo-scan](CI.md#repo-scan)).
- **Code and image scans:** gosec (SAST) and govulncheck (SCA) on source ([CI.md#sast-and-sca](CI.md#sast-and-sca)). trivy on each arch image fails on any CRITICAL/HIGH, with unreachable Go CVEs filtered out ([CI.md#image-scan](CI.md#image-scan)).
- **Supply chain:** every CI tool is pinned and checksum-verified ([CI.md#tool-pins](CI.md#tool-pins)). Untrusted input reaches scripts only via `env:` ([CI.md#script-injection](CI.md#script-injection)). `packages: write` is granted only to jobs that push.
- **On EKS:** IRSA/Pod Identity instead of node credentials, Secrets from AWS Secrets Manager via External Secrets, KMS envelope encryption for etcd, private API endpoint, ECR scan-on-push as a second scanner.

## CI/CD pipeline

[L111](../README.md?plain=1#L111). GitHub Actions, split by what changed. Every check gates. Scans are reusable workflows, shared by CI and release. Depth: [CI.md](CI.md).

| Workflow | Does |
|---|---|
| `app-ci.yml` | Go lint, unit tests, SAST/SCA, multi-arch build to GHCR, image scan, e2e (container, static binary, minikube, zero-downtime rollout) on amd64 + arm64 |
| `helm-ci.yml` | helm lint, kubeconform, kube-linter, trivy config on the rendered chart |
| `common-ci.yml` | actionlint, ruff, pytest (100% coverage), doc links, repo secret scan. No path filter |
| `release.yml` | On `vX.Y.Z` tag: build by digest, same scans as gate, then tag, binaries, GitHub Release ([RELEASE.md](RELEASE.md)) |
| `cleanup.yml` | Weekly GHCR retention |

- **Gating:** lint, tests and scans fail fast, so later jobs don't spend runner time. e2e runs every suite, then fails if any failed, so one run shows everything broken ([CI.md#gating](CI.md#gating)).
- **Visibility:** every run ends with a Tests and a Security table, per arch ([CI.md#build-summary](CI.md#build-summary)).
- **Speed:** BuildKit registry cache per branch, falling back to `main-cache` ([CI.md#build-cache](CI.md#build-cache)). Tools, Go, minikube and trivy DB cached ([CI.md#tool-cache](CI.md#tool-cache)).
- **Local:** act wrapper and a minikube script run the same steps on a laptop ([LOCAL-TESTING.md](LOCAL-TESTING.md)).

## Multi-architecture builds

[L112](../README.md?plain=1#L112). One `docker buildx build --platform linux/amd64,linux/arm64` on one amd64 runner. No QEMU.

- **How:** the Go stage runs on `$BUILDPLATFORM` and cross-compiles with `GOOS`/`GOARCH`, `CGO_ENABLED=0` ([CONTAINER.md#cross-compile](CONTAINER.md#cross-compile)). No step executes target-arch code, so the build stays fast.
- **Output:** one OCI index `<image>:<sha>` holding both arches. Clients pull their own arch automatically ([CI.md#build](CI.md#build)).
- **Binaries:** the release binary is copied out of the image, so container and binary are the same bytes. CI checks it's static ([CI.md#static-binary](CI.md#static-binary)).
- **Testing:** e2e runs on native amd64 and arm64 runners, and fails unless the runner pulled its own arch from the index.
- **Scanning:** trivy scans each arch separately.
- **darwin:** amd64/arm64 binaries are cross-compiled in release ([RELEASE.md#binaries](RELEASE.md#binaries)).

## Versioning and tagging strategy

[L113](../README.md?plain=1#L113). SemVer git tags drive releases. A release builds once, pushes by digest, scans that digest, and only then tags it ([RELEASE.md](RELEASE.md)).

| Tag | Made by | Lifetime |
|---|---|---|
| `<sha>` (full commit SHA) | every CI run | 14 days, then pruned |
| `<branch-slug>-cache` | CI build cache | until the branch is deleted |
| `main-cache` | CI on `main` | kept |
| `vX.Y.Z` | `release.yml`, after scans pass | forever |

- **Scan, then tag:** `release.yml` builds with the tag stamped in, pushes by digest only, scans that digest, then tags that exact digest `vX.Y.Z`. What ships is what was scanned ([RELEASE.md#pipeline](RELEASE.md#pipeline)).
- **No `latest`:** kube-linter's `latest-tag` check blocks it in the chart. Deploys reference an immutable version.
- **Binary:** `-ldflags -X` stamps the version, so `--version` and `/health` report the tag ([CONTAINER.md#version](CONTAINER.md#version)).
- **Release:** pushing `vX.Y.Z` creates a GitHub Release with linux/darwin binaries and checksums.
- **Deploys:** pin by digest (`image@sha256:...`), so a re-pushed tag can't change what runs.

## Going cloud with EKS

[L114](../README.md?plain=1#L114). The same chart deploys to EKS. Only values and cluster add-ons change.

**Cluster (Terraform or eksctl):**

1. VPC with private subnets for nodes, public subnets for the NLB only. Private API endpoint.
2. Managed node groups or Karpenter, Graviton (arm64) first, amd64 as fallback. The chart already prefers arm64.
3. Add-ons: AWS Load Balancer Controller, EBS CSI (if storage is ever needed), VPC CNI with network policy enabled, External Secrets Operator.
4. Pod Security Admission `restricted` label on the app namespace ([HELM.md#pod-security-admission](HELM.md#pod-security-admission)).

**App:**

1. Image: pull from GHCR with an `imagePullSecret`, or mirror to ECR (see next section). Nodes pull ECR with their IAM role, no secret needed.
2. Secret: store the token in AWS Secrets Manager. External Secrets syncs it into `echo-pong-auth`.
3. Ingress: `gateway.serviceType=LoadBalancer` gives an NLB in front of Envoy ([HELM.md#envoy-gateway](HELM.md#envoy-gateway)). TLS via ACM on the NLB, or cert-manager on the Gateway. Optional AWS WAF via CloudFront or an ALB in front.
4. Shared cluster: install Envoy Gateway once, separately, and set `envoy-gateway.enabled=false` in the app release.
5. Deploy: a workflow assumes an IAM role via GitHub OIDC (no long-lived AWS keys), then runs `helm upgrade --install --atomic` with the released chart version. Or GitOps (Argo CD) watching a values repo.
6. Observability: CloudWatch Container Insights or Prometheus/Grafana; Envoy access logs.

## Fast global image pulls with AWS

[L115](../README.md?plain=1#L115). Keep a copy of the image in each region the teams work in. Every pull then stays in-region.

- **ECR cross-region replication:** CI pushes once to a primary ECR registry. A replication rule copies each image to the other regions (e.g. `us-east-1`, `eu-west-1`, `ap-southeast-1`). Teams and clusters pull from their nearest region. Multi-arch indexes replicate intact.
- **ECR pull-through cache:** alternative to pushing. Each regional ECR caches `ghcr.io/yoyobesser/echo-pong` on first pull. GHCR stays the source of truth, with no extra push step.
- **Cross-account:** a registry policy, or ECR replication to other accounts, lets each team's account pull without sharing credentials.
- **Inside the cluster:** pin images by digest and use `IfNotPresent`, so nodes reuse layers. The small distroless image keeps pulls fast anyway.
- **Not CloudFront:** OCI registries need auth and range requests. Regional ECR is the supported AWS answer.

## Managing older and stale versions

[L116](../README.md?plain=1#L116). A weekly cleanup workflow applies a retention policy to GHCR. Releases are never deleted ([CI.md#image-cleanup](CI.md#image-cleanup)).

- **Kept:** every `vX.Y.Z`, `main-cache`, caches of live branches, `<sha>` images under 14 days, unknown tags.
- **Deleted:** `<sha>` images over 14 days, caches of deleted branches, untagged versions not referenced by a kept index.
- **Gotcha:** GHCR lists each per-arch manifest of a multi-arch image as an untagged version. "Delete all untagged" would break kept images. The script reads each kept index and protects its children.
- **Safe to run:** manual runs default to dry run. Every run writes a keep/delete table, with the reason per version, to the summary. Only the cleanup job gets `packages: write`.
- **Old releases in use:** releases stay pullable for rollback. Deprecate old versions by policy (e.g. support the last N minors), not by deleting images that may still run somewhere.
- **On ECR:** use ECR lifecycle policies for the same rules (expire untagged after N days, keep `v*` tags).
- **Deployed versions:** Helm keeps release history for `helm rollback`. Cap it with `--history-max`.
