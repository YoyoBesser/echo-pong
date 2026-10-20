# Tasks

Each bold line quotes a requirement from the assignment [README](../README.md), with its line number. The bullets under it say how we meet it: `[x]` done, `[ ]` planned.

## Application

- **[L23](../README.md?plain=1#L23) / [L35](../README.md?plain=1#L35): `SECRET_FILE_PATH` - Path to secret file**
  - [x] Chart mounts Secret `auth.existingSecret` read-only and sets `SECRET_FILE_PATH` ([HELM.md#auth-secret](HELM.md#auth-secret))
- **[L32](../README.md?plain=1#L32): The server will think for 10 seconds before starting the server**
  - [x] `startupProbe` allows 30s before liveness takes over ([HELM.md#probes](HELM.md#probes))
  - [x] e2e waits up to 45s for `/health` ([CI.md#e2e-tests](CI.md#e2e-tests))
- **[L33](../README.md?plain=1#L33): health check endpoint is available at `/health` ...**
  - [x] Startup, readiness and liveness probes all hit `/health`
- **[L75](../README.md?plain=1#L75): Go 1.24**
  - [x] `src/go.mod` pins `go 1.24`; CI's `setup-go` reads it ([CI.md#tool-pins](CI.md#tool-pins))

## Mission

- **[L42](../README.md?plain=1#L42): Take this application to production with support for both x86 and ARM64 ... binary release and a container release**
  - [x] One buildx build for amd64 + arm64, pushed as a multi-arch index ([CI.md#build](CI.md#build))
  - [x] Static linux binaries (amd64, arm64) extracted from the CI image, e2e-tested on ubuntu + alpine ([CI.md#binary-e2e](CI.md#binary-e2e))
  - [ ] Release: multi-arch image to GHCR + binaries on GitHub Releases (`release.yml` placeholders)

## Security

- **[L49](../README.md?plain=1#L49): No containers running as root**
  - [x] Image runs as numeric UID `65532` ([CONTAINER.md#non-root](CONTAINER.md#non-root))
  - [x] kube-linter: `run-as-non-root`, `privileged-container`, `privilege-escalation-container`
  - [x] Blocking gate: trivy config KSV-0001 (`allowPrivilegeEscalation`), KSV-0012 (`runAsNonRoot`) on the rendered chart ([CI.md#trivy-config](CI.md#trivy-config))
  - [x] Chart `securityContext`: `runAsNonRoot`, UID 65532, `allowPrivilegeEscalation: false`, drop `ALL` caps, seccomp `RuntimeDefault` ([HELM.md#security-context](HELM.md#security-context))
- **[L50](../README.md?plain=1#L50): All images must pass security scans**
  - [x] trivy scans each arch image (vuln + image misconfig), Go CVEs filtered by `trivy-plugin-govulncheck` ([CI.md#image-scan](CI.md#image-scan), soft-fail for now)
  - [x] gosec (SAST) + govulncheck (SCA) on source ([CI.md#sast-and-sca](CI.md#sast-and-sca), soft-fail for now)
- **[L51](../README.md?plain=1#L51): No critical/high vulnerabilities should be released to production**
  - [x] Distroless static base keeps CVE surface near zero ([CONTAINER.md#base-image](CONTAINER.md#base-image))
  - [x] CI fails on CRITICAL/HIGH, fixed or not (soft-fail until Go toolchain is bumped: 22 HIGH stdlib CVEs in Go 1.24)
  - [ ] Scan gate in `release.yml` before any push; fail on CRITICAL/HIGH
- **[L52](../README.md?plain=1#L52): No secrets in codebase**
  - [x] Token only in an out-of-band Secret, never in values ([HELM.md#auth-secret](HELM.md#auth-secret))
  - [x] e2e generates a random token per run
  - [x] kube-linter: `env-var-secret`, `read-secret-from-env-var`
  - [ ] Secret scanning in CI (`secret-scan` placeholder)
- **[L53](../README.md?plain=1#L53): Proper filesystem isolation**
  - [x] Distroless image; `.dockerignore` allowlist (`go.mod`, `*.go` only)
  - [x] Secret volume mounted `readOnly`
  - [x] kube-linter: `no-read-only-root-fs`, host mount, `docker-sock`, `host-pid`/`host-ipc` checks
  - [x] Gate: trivy config KSV-0014 (`readOnlyRootFilesystem`) ([CI.md#trivy-config](CI.md#trivy-config))
  - [x] Chart `readOnlyRootFilesystem: true`; minikube e2e runs with it

## Kubernetes

- **[L56](../README.md?plain=1#L56): Zero-downtime deployments server must be available and ready at all times**
  - [x] 2 replicas; startup/readiness/liveness probes on `/health`
  - [x] kube-linter: probes, replica floor 2, rolling update, anti-affinity, PDB checks ([CI.md#kube-linter-policy](CI.md#kube-linter-policy))
  - [ ] `RollingUpdate` with `maxUnavailable: 0`, PDB, pod anti-affinity
  - [ ] App graceful shutdown on SIGTERM
  - [ ] Verify zero-downtime rollout (traffic during `helm upgrade`)
- **[L57](../README.md?plain=1#L57): ARM64 architecture preferred**
  - [x] arm64 image built and e2e-tested on an arm64 runner
  - [ ] `preferredDuringScheduling` node affinity for `kubernetes.io/arch: arm64`
- **[L58](../README.md?plain=1#L58): No direct internet access (use ingress/proxy)**
  - [x] Envoy Gateway + Gateway API; Envoy and app Services `ClusterIP` ([HELM.md#envoy-gateway](HELM.md#envoy-gateway))
  - [x] minikube e2e reaches the app only through the Gateway ([CI.md#minikube-e2e](CI.md#minikube-e2e))
  - [x] kube-linter: `exposed-services`, `host-network`, `non-isolated-pod`
  - [ ] NetworkPolicy: app accepts traffic only from Envoy
- **[L59](../README.md?plain=1#L59): Cluster can pull from registry**
  - [x] e2e preloads the image (`pullPolicy: Never`)
  - [ ] Public GHCR package, or `imagePullSecrets` if private

## CI/CD

- **[L62](../README.md?plain=1#L62): Multi-architecture builds (x86/ARM64)**
  - [x] Single multi-platform buildx build, no QEMU; Dockerfile cross-compiles ([CONTAINER.md#cross-compile](CONTAINER.md#cross-compile))
  - [x] Multi-arch OCI index per commit; e2e pulls it on native amd64 + arm64 runners
  - [ ] Multi-arch manifest on release
- **[L63](../README.md?plain=1#L63): Images stored in GitHub Container Registry**
  - [x] CI pushes every commit to `ghcr.io/yoyobesser/echo-pong:<sha>` (multi-arch), registry build cache `<branch-slug>-cache` / `main-cache` ([CI.md#image-tags](CI.md#image-tags))
  - [ ] `release.yml` pushes `ghcr.io/yoyobesser/echo-pong` with version tags
  - [ ] Chart pushed to GHCR as OCI
- **[L64](../README.md?plain=1#L64): Versioned releases with tags**
  - [x] `release.yml` triggers on `vX.Y.Z` tags
  - [x] kube-linter: `latest-tag`
  - [ ] Version injected into binary; chart version tracks app version
- **[L65](../README.md?plain=1#L65): Both container and binary releases**
  - [x] linux amd64/arm64 binary = the image's binary, verified static and run on ubuntu + alpine ([CI.md#binary-e2e](CI.md#binary-e2e))
  - [ ] Publish linux binaries + cross-compiled darwin amd64/arm64 on GitHub Releases
  - [ ] Image signing + SBOM

## Evaluation

- **[L83](../README.md?plain=1#L83): Container Security**: see L49–L53
  - [x] Gate: trivy config KSV-0003 (drop `ALL` capabilities)
- **[L84](../README.md?plain=1#L84): Kubernetes Manifests and best practices**
  - [x] Helm chart, `helm lint --strict`, `kubeconform -strict` incl. CRDs ([CI.md#chart-lint](CI.md#chart-lint))
  - [x] README-traced kube-linter policy (soft-fail for now, [CI.md#soft-fail](CI.md#soft-fail))
  - [ ] Chart passes the policy: resources, HPA, ServiceAccount, `values-<env>.yaml`
- **[L85](../README.md?plain=1#L85): CI/CD Pipeline container and binary releases**
  - [x] `app-ci.yml` + `helm-ci.yml` + `github-ci.yml`, path-filtered ([CI.md#workflow-split](CI.md#workflow-split)); shared actions; act for local runs
  - [x] Tests + Security summary tables in every run ([CI.md#build-summary](CI.md#build-summary))
  - [x] Doc links checked in CI: repo-root relative, anchors resolve ([CI.md#doc-links](CI.md#doc-links))
  - [x] Every tool/action pin on latest, annotated with source + check date ([CI.md#tool-pins](CI.md#tool-pins))
  - [x] Tool, Go, minikube, trivy DB and schema downloads cached across runs ([CI.md#tool-cache](CI.md#tool-cache))
  - [ ] Golangci-lint blocking (fix 11 existing `main.go` issues)
  - [ ] `release.yml` + `cd.yml` (placeholders), see L63–L65
- **[L86](../README.md?plain=1#L86): Multi-Architecture builds**: see L62
- **[L87](../README.md?plain=1#L87): Security Scanning and release prevention for critical and high vulnerabilities**: see L50–L51
- **[L90](../README.md?plain=1#L90)–[L94](../README.md?plain=1#L94): Architecture decisions, Scaling strategy, Cloud deployment considerations, Security measures, Maintaining image versions and tags and removing old ones**
  - [x] Per-area reference docs (`CI.md`, `CONTAINER.md`, `HELM.md`, `LOCAL-TESTING.md`), [CHANGELOG.md](CHANGELOG.md) per PR
  - [ ] Docs for scaling (HPA), security, EKS, versioning and image retention
  - [ ] Scheduled GHCR cleanup of old/untagged images

## Deliverables

- **[L100](../README.md?plain=1#L100): `Dockerfile`**
  - [x] `src/Dockerfile`, next to the app it builds ([CONTAINER.md](CONTAINER.md))
- **[L101](../README.md?plain=1#L101): `k8s/` manifests**
  - [x] Helm chart `helm/echo-pong` instead of raw manifests ([HELM.md](HELM.md))
- **[L102](../README.md?plain=1#L102): `.github/workflows/` CI/CD pipeline**
  - [x] `app-ci.yml`, `helm-ci.yml`; [ ] `release.yml`, `cd.yml`
- **[L103](../README.md?plain=1#L103): Documentation of your approach**
  - [ ] Docs entry point linking every area; explain `helm/` and `src/` vs the README's `k8s/` and root `Dockerfile`
- **[L105](../README.md?plain=1#L105): Use Minikube/Kind for testing. Be prepared to explain real cloud deployment strategy.**
  - [x] `minikube-e2e.sh` deploys the chart and tests through the Gateway, locally and in CI ([LOCAL-TESTING.md#minikube-e2e](LOCAL-TESTING.md#minikube-e2e))
  - [ ] EKS deployment doc (see L114)

## To explain

- **[L108](../README.md?plain=1#L108): The deployment strategy**: [ ] doc (Helm, rolling update, Gateway)
- **[L109](../README.md?plain=1#L109): The scaling strategy**: [ ] doc (HPA, replica floor, PDB)
- **[L110](../README.md?plain=1#L110): The security measures**: [ ] `SECURITY.md` (summarise L49–L53)
- **[L111](../README.md?plain=1#L111): The CI/CD pipeline**: [x] [CI.md](CI.md); [ ] release + CD sections
- **[L112](../README.md?plain=1#L112): The multi-architecture builds**: [x] [CI.md#build](CI.md#build), [CONTAINER.md#cross-compile](CONTAINER.md#cross-compile)
- **[L113](../README.md?plain=1#L113): The versioning and tagging strategy**: [ ] `RELEASE.md`
- **[L114](../README.md?plain=1#L114): Going cloud with EKS and how to deploy the application to EKS**: [ ] doc (EKS, NLB via `gateway.serviceType: LoadBalancer`)
- **[L115](../README.md?plain=1#L115): How to allow teams from across the world to pull the image fast using AWS solutions**: [ ] doc (ECR cross-region replication / pull-through cache)
- **[L116](../README.md?plain=1#L116): How to manage older and stale versions of the application**: [ ] doc + scheduled cleanup (see L94)
