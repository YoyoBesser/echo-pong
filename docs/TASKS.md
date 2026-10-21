# Tasks

Each bold line quotes a requirement from the assignment [README](../README.md), with its line number. The bullets under it say how we meet it: `[x]` done, `[ ]` planned.

## Contents

- [Application](#application)
- [Mission](#mission)
- [Security](#security)
- [Kubernetes](#kubernetes)
- [CI/CD](#cicd)
- [Evaluation](#evaluation)
- [Deliverables](#deliverables)
- [To explain](#to-explain)

## Application

- **[L23](../README.md?plain=1#L23) / [L35](../README.md?plain=1#L35): `SECRET_FILE_PATH` - Path to secret file**
  - [x] Chart mounts Secret `auth.existingSecret` read-only and sets `SECRET_FILE_PATH` ([HELM.md#auth-secret](HELM.md#auth-secret))
- **[L32](../README.md?plain=1#L32): The server will think for 10 seconds before starting the server**
  - [x] `startupProbe` allows 30s before liveness takes over ([HELM.md#probes](HELM.md#probes))
  - [x] e2e waits up to 45s for `/health` ([CI.md#e2e-tests](CI.md#e2e-tests))
- **[L33](../README.md?plain=1#L33): health check endpoint is available at `/health` ...**
  - [x] Startup, readiness and liveness probes all hit `/health`
- **[L75](../README.md?plain=1#L75): Go 1.24**
  - [x] `src/go.mod` keeps `go 1.24` (language version) and builds with `toolchain go1.27.3` (patched stdlib); CI's `setup-go` reads it ([CONTAINER.md#go-toolchain](CONTAINER.md#go-toolchain))

## Mission

- **[L42](../README.md?plain=1#L42): Take this application to production with support for both x86 and ARM64 ... binary release and a container release**
  - [x] One buildx build for amd64 + arm64, pushed as a multi-arch index ([CI.md#build](CI.md#build))
  - [x] Static linux binaries (amd64, arm64) extracted from the CI image and verified static ([CI.md#static-binary](CI.md#static-binary))
  - [x] Release: multi-arch image to GHCR + binaries on GitHub Releases ([RELEASE.md#pipeline](RELEASE.md#pipeline))

## Security

- **[L49](../README.md?plain=1#L49): No containers running as root**
  - [x] Image runs as numeric UID `65532` ([CONTAINER.md#non-root](CONTAINER.md#non-root))
  - [x] kube-linter: `run-as-non-root`, `privileged-container`, `privilege-escalation-container`
  - [x] kube-linter `run-as-non-root` in Helm CI; PSA `restricted` in the e2e namespace rejects pods without `allowPrivilegeEscalation: false` ([HELM.md#pod-security-admission](HELM.md#pod-security-admission))
  - [x] Chart `securityContext`: `runAsNonRoot`, UID 65532, `allowPrivilegeEscalation: false`, drop `ALL` caps, seccomp `RuntimeDefault` ([HELM.md#security-context](HELM.md#security-context))
- **[L50](../README.md?plain=1#L50): All images must pass security scans**
  - [x] trivy scans each arch image: OS packages, Go stdlib/modules, image config ([CI.md#image-scan](CI.md#image-scan), gating)
  - [x] gosec (SAST) via golangci-lint on every PR ([CI.md#sast-and-sca](CI.md#sast-and-sca), gating)
- **[L51](../README.md?plain=1#L51): No critical/high vulnerabilities should be released to production**
  - [x] Distroless static base keeps CVE surface near zero ([CONTAINER.md#base-image](CONTAINER.md#base-image))
  - [x] CI fails on CRITICAL/HIGH, fixed or not; 0 findings since the go1.27.3 toolchain bump ([CONTAINER.md#go-toolchain](CONTAINER.md#go-toolchain))
  - [x] Release gate: `release.yml` calls the same reusable scans; `publish` (the `vX.Y.Z` retag) needs both ([CI.md#reusable-scans](CI.md#reusable-scans))
  - [x] Release builds and pushes by digest, tags only the scanned digest ([RELEASE.md#pipeline](RELEASE.md#pipeline))
- **[L52](../README.md?plain=1#L52): No secrets in codebase**
  - [x] Token only in an out-of-band Secret, never in values ([HELM.md#auth-secret](HELM.md#auth-secret))
  - [x] e2e generates a random token per run
  - [x] kube-linter: `env-var-secret`, `read-secret-from-env-var`
  - [x] gitleaks over the full git history on every commit, blocking ([CI.md#repo-scan](CI.md#repo-scan)); also in the release gate
- **[L53](../README.md?plain=1#L53): Proper filesystem isolation**
  - [x] Distroless image; `.dockerignore` allowlist (`go.mod`, `*.go` only)
  - [x] Secret volume mounted `readOnly`
  - [x] kube-linter: `no-read-only-root-fs`, host mount, `docker-sock`, `host-pid`/`host-ipc` checks
  - [x] kube-linter `no-read-only-root-fs` in Helm CI ([CI.md#kube-linter-policy](CI.md#kube-linter-policy))
  - [x] Chart `readOnlyRootFilesystem: true`; minikube e2e runs with it

## Kubernetes

- **[L56](../README.md?plain=1#L56): Zero-downtime deployments server must be available and ready at all times**
  - [x] 2 replicas; startup/readiness/liveness probes on `/health`
  - [x] kube-linter: probes, replica floor 2, rolling update, anti-affinity, PDB checks ([CI.md#kube-linter-policy](CI.md#kube-linter-policy))
  - [x] `RollingUpdate` with `maxUnavailable: 0`, PDB, pod anti-affinity ([HELM.md#zero-downtime](HELM.md#zero-downtime))
  - [x] App graceful shutdown on SIGTERM (drain in-flight, exit 0) + `preStop` sleep ([HELM.md#zero-downtime](HELM.md#zero-downtime))
  - [x] Rolling restart checked on every PR: 0 failed requests through the Gateway, single-node minikube ([CI.md#rollout-verification](CI.md#rollout-verification))
- **[L57](../README.md?plain=1#L57): ARM64 architecture preferred**
  - [x] arm64 image built and e2e-tested on an arm64 runner
  - [x] `preferredDuringScheduling` node affinity for `kubernetes.io/arch: arm64` ([HELM.md#scheduling](HELM.md#scheduling))
- **[L58](../README.md?plain=1#L58): No direct internet access (use ingress/proxy)**
  - [x] Envoy Gateway + Gateway API; Envoy and app Services `ClusterIP` ([HELM.md#envoy-gateway](HELM.md#envoy-gateway))
  - [x] minikube e2e reaches the app only through the Gateway ([CI.md#minikube-e2e](CI.md#minikube-e2e))
  - [x] kube-linter: `exposed-services`, `host-network`, `non-isolated-pod`
  - [x] NetworkPolicy: app accepts traffic only from Envoy; enforced on minikube ([HELM.md#network-policy](HELM.md#network-policy))
- **[L59](../README.md?plain=1#L59): Cluster can pull from registry**
  - [x] e2e preloads the image (`pullPolicy: Never`)
  - [x] GHCR package is public (anonymous pull works); chart supports `imagePullSecrets` if it goes private ([HELM.md#image-pull](HELM.md#image-pull))
  - [ ] In-cluster pull not tested: minikube flows preload the image

## CI/CD

- **[L62](../README.md?plain=1#L62): Multi-architecture builds (x86/ARM64)**
  - [x] Single multi-platform buildx build, no QEMU; Dockerfile cross-compiles ([CONTAINER.md#cross-compile](CONTAINER.md#cross-compile))
  - [x] Multi-arch OCI index per commit; e2e pulls it on native amd64 + arm64 runners
  - [x] Multi-arch index on release (`vX.Y.Z`)
- **[L63](../README.md?plain=1#L63): Images stored in GitHub Container Registry**
  - [x] CI pushes every commit to `ghcr.io/yoyobesser/echo-pong:<sha>` (multi-arch), registry build cache `<branch-slug>-cache` / `main-cache` ([CI.md#image-tags](CI.md#image-tags))
  - [x] `release.yml` tags `ghcr.io/yoyobesser/echo-pong:vX.Y.Z` ([RELEASE.md#versioning](RELEASE.md#versioning))
- **[L64](../README.md?plain=1#L64): Versioned releases with tags**
  - [x] `release.yml` triggers on `vX.Y.Z` tags
  - [x] kube-linter: `latest-tag`
  - [x] Version injected into binary (`--version`, `/health`) ([CONTAINER.md#version](CONTAINER.md#version))
- **[L65](../README.md?plain=1#L65): Both container and binary releases**
  - [x] linux amd64/arm64 binary = the image's binary, verified static ([CI.md#static-binary](CI.md#static-binary))
  - [x] linux + cross-compiled darwin amd64/arm64 binaries with checksums on GitHub Releases ([RELEASE.md#binaries](RELEASE.md#binaries))
  - [x] SBOM + provenance attestations on the release image ([RELEASE.md#attestations](RELEASE.md#attestations))

## Evaluation

- **[L83](../README.md?plain=1#L83): Container Security**: see L49–L53
  - [x] Drop `ALL` capabilities enforced by PSA `restricted` in e2e ([HELM.md#pod-security-admission](HELM.md#pod-security-admission))
- **[L84](../README.md?plain=1#L84): Kubernetes Manifests and best practices**
  - [x] Helm chart, `helm lint --strict`, `kubeconform -strict` incl. CRDs ([CI.md#chart-lint](CI.md#chart-lint))
  - [x] README-traced kube-linter policy, gating ([CI.md#gating](CI.md#gating))
  - [x] Chart passes the policy: resources, ServiceAccount (no token automount), NetworkPolicy ([HELM.md#resources](HELM.md#resources))
  - [x] HPA (off by default, needs metrics-server) and `values-local.yaml`, both linted in CI ([HELM.md#autoscaling](HELM.md#autoscaling), [HELM.md#local-values](HELM.md#local-values))
- **[L85](../README.md?plain=1#L85): CI/CD Pipeline container and binary releases**
  - [x] `app-ci.yml` + `helm-ci.yml` + `common-ci.yml`, path-filtered ([CI.md#workflow-split](CI.md#workflow-split)); shared actions; act for local runs
  - [x] Tests + Security summary tables in every run ([CI.md#build-summary](CI.md#build-summary))
  - [x] Doc links checked in CI: repo-root relative, anchors resolve ([CI.md#doc-links](CI.md#doc-links))
  - [x] Every tool/action pin on latest, annotated with source + check date ([CI.md#tool-pins](CI.md#tool-pins))
  - [x] Tool, Go, minikube, trivy DB and schema downloads cached across runs ([CI.md#tool-cache](CI.md#tool-cache))
  - [x] Every check gating: lint, unit tests and scans fail fast; e2e runs all suites, then fails on any ([CI.md#gating](CI.md#gating))
  - [x] Fixed the existing `main.go` findings (golangci-lint, `go vet`, gosec) without changing behavior; e2e untouched ([CI.md#gosec-exceptions](CI.md#gosec-exceptions))
  - [x] `release.yml`: digest-only build, scan gate, tag, binaries ([RELEASE.md](RELEASE.md)). Deploys are out of scope: no CD workflow
- **[L86](../README.md?plain=1#L86): Multi-Architecture builds**: see L62
- **[L87](../README.md?plain=1#L87): Security Scanning and release prevention for critical and high vulnerabilities**: see L50–L51
- **[L90](../README.md?plain=1#L90)–[L94](../README.md?plain=1#L94): Architecture decisions, Scaling strategy, Cloud deployment considerations, Security measures, Maintaining image versions and tags and removing old ones**
  - [x] Per-area reference docs (`CI.md`, `CONTAINER.md`, `HELM.md`, `LOCAL-TESTING.md`), [CHANGELOG.md](CHANGELOG.md) per PR
  - [x] [EXPLAIN.md](EXPLAIN.md): deployment, scaling, security, CI/CD, versioning, EKS, global pulls, stale versions
  - [x] Weekly GHCR cleanup (`cleanup.yml`): keeps releases, recent commits, live-branch caches and index children; dry-run on demand ([CI.md#image-cleanup](CI.md#image-cleanup)) Not run yet

## Deliverables

- **[L100](../README.md?plain=1#L100): `Dockerfile`**
  - [x] `src/Dockerfile`, next to the app it builds ([CONTAINER.md](CONTAINER.md))
- **[L101](../README.md?plain=1#L101): `k8s/` manifests**
  - [x] Helm chart `helm/echo-pong` instead of raw manifests ([HELM.md](HELM.md))
- **[L102](../README.md?plain=1#L102): `.github/workflows/` CI/CD pipeline**
  - [x] `app-ci.yml`, `helm-ci.yml`, `common-ci.yml`, `release.yml`, `cleanup.yml`, reusable `scan-*.yml` ([GITHUB.md](GITHUB.md))
- **[L103](../README.md?plain=1#L103): Documentation of your approach**
  - [x] Docs entry point [docs/README.md](README.md): every doc, and why `helm/` + `src/Dockerfile` instead of `k8s/` + root `Dockerfile`
- **[L105](../README.md?plain=1#L105): Use Minikube/Kind for testing. Be prepared to explain real cloud deployment strategy.**
  - [x] `minikube-e2e.sh` deploys the chart and tests through the Gateway, locally and in CI ([LOCAL-TESTING.md#minikube-e2e](LOCAL-TESTING.md#minikube-e2e))
  - [x] `scripts/minikube-up.sh`: local build or GHCR tag, deploy, real ingress via `minikube tunnel`, `--test` runs every suite ([LOCAL-TESTING.md#minikube-up](LOCAL-TESTING.md#minikube-up))
  - [x] EKS deployment: [EXPLAIN.md#going-cloud-with-eks](EXPLAIN.md#going-cloud-with-eks)

## To explain

- **[L108](../README.md?plain=1#L108): The deployment strategy**: [x] [EXPLAIN.md#deployment-strategy](EXPLAIN.md#deployment-strategy)
- **[L109](../README.md?plain=1#L109): The scaling strategy**: [x] [EXPLAIN.md#scaling-strategy](EXPLAIN.md#scaling-strategy)
- **[L110](../README.md?plain=1#L110): The security measures**: [x] [EXPLAIN.md#security-measures](EXPLAIN.md#security-measures)
- **[L111](../README.md?plain=1#L111): The CI/CD pipeline**: [x] [EXPLAIN.md#cicd-pipeline](EXPLAIN.md#cicd-pipeline), [CI.md](CI.md), [RELEASE.md](RELEASE.md)
- **[L112](../README.md?plain=1#L112): The multi-architecture builds**: [x] [EXPLAIN.md#multi-architecture-builds](EXPLAIN.md#multi-architecture-builds)
- **[L113](../README.md?plain=1#L113): The versioning and tagging strategy**: [x] [EXPLAIN.md#versioning-and-tagging-strategy](EXPLAIN.md#versioning-and-tagging-strategy), [RELEASE.md#versioning](RELEASE.md#versioning)
- **[L114](../README.md?plain=1#L114): Going cloud with EKS and how to deploy the application to EKS**: [x] [EXPLAIN.md#going-cloud-with-eks](EXPLAIN.md#going-cloud-with-eks)
- **[L115](../README.md?plain=1#L115): How to allow teams from across the world to pull the image fast using AWS solutions**: [x] [EXPLAIN.md#fast-global-image-pulls-with-aws](EXPLAIN.md#fast-global-image-pulls-with-aws)
- **[L116](../README.md?plain=1#L116): How to manage older and stale versions of the application**: [x] [EXPLAIN.md#managing-older-and-stale-versions](EXPLAIN.md#managing-older-and-stale-versions), [CI.md#image-cleanup](CI.md#image-cleanup)
