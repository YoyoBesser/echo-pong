# Changelog

All notable changes to echo-pong are documented here.

Agents and contributors **must append an entry** for every merged PR that changes
app behaviour, tooling, workflows, repo guardrails, or delivery configuration
(container image, Helm chart). See [`AGENTS.md`](../AGENTS.md) and [`docs/AGENTS.md`](AGENTS.md).

## Format

Append entries at the top of the changelog, below this section (newest first). Every entry title uses
this format (omit the PR segment for direct commits to `main`, and don't leave an
empty placeholder):

`YYYY-MM-DD - <PR URL> - short title`

- **Date**: merge date (or land date for direct commits to `main`).
- **PR URL**: link to the merged pull request (e.g.
  `[#1](https://github.com/YoyoBesser/echo-pong/pull/1)`). Omit if none.
- **short title**: one line, no em dash.

Every PR entry requires:

- **Intent** and **Result**: one sentence each, in **caveman `/lite`** style (no filler, tight full sentences). Goal and outcome only: no commit lists, no implementation steps.
- **authors**: comma-separated GitHub logins for everyone who contributed (PR commits, direct commits, docs edits).
- Structured fields: **dependencies**, **workflows**, **delivery**, **guardrails** and **breaking changes**. Keep the set the same in every entry.
- A mandatory **Action needed** field: what the user must do after pulling the change.

### Action needed values

| Value | When to use |
|-------|-------------|
| `none` | Content-only changes: docs, guardrails, comments |
| `run: <install command>` | New or updated tool dependencies (e.g. `brew install minikube`) |
| `restart: <service>` | A running service or agent must restart to pick up the change |
| `migrate: <scope>` | Breaking config or schema change; manual migration required |
| `run: helm dependency build helm/echo-pong` | `Chart.yaml`/`Chart.lock` dependencies changed (`helm/*/charts/` is gitignored) |
| `rebuild: docker buildx build --load -t echo-pong:ci src/` | `src/Dockerfile` or app code changed and local e2e uses a stale image |
| `recreate: minikube delete -p echo-pong-e2e` | Cluster-scoped chart pieces (CRDs, GatewayClass) changed and you kept a cluster (`KEEP_CLUSTER=1`) |

### Entry template

```markdown
### YYYY-MM-DD - [#N](https://github.com/YoyoBesser/echo-pong/pull/N) - short title

**Intent:** One sentence, why.

**Result:** One sentence, what users get.

- **authors:** login1, login2
- **dependencies:** Go app moved to `src/` (unchanged); base images `gcr.io/distroless/static-debian13:nonroot` + `busybox:musl`; chart dependency `gateway-helm` 1.9.2; CI tool pins (all latest as of 2026-10-21) in `.github/actions/install-ci-tools`; Python dev deps (ruff, pytest, pytest-cov) in `.github/pyproject.toml` + `uv.lock`, Python 3.14 from `.github/.python-version`
- **workflows:** none | what changed in `.github/workflows/`, `.github/actions/` or CI
- **delivery:** none | what changed in the image (`src/Dockerfile`) or chart (`helm/`)
- **guardrails:** none | new or changed tests, linters, policies or AGENTS rules
- **breaking changes:** none | incompatible behaviour or config
- **Action needed:** none
```

---

### 2026-10-21 - Gate CI and fix every finding

**Intent:** Make CI a real guardrail, then make the original code and chart pass it without changing app behavior.

**Result:** Every check gates and passes: lint, unit tests and scans fail fast, e2e runs every suite and fails on any, with zero lint, SAST, SCA, image or chart findings.

- **authors:** YoyoBesser
- **dependencies:** Go toolchain go1.27.3 (`toolchain` line in `src/go.mod`, builder `golang:1.27.3`), language version stays `go 1.24`
- **workflows:** `continue-on-error` removed from every check; reusable scans always blocking; `test` runs `go test -race -vet=off ./...`; e2e suites run with `if: !cancelled()`; ubuntu/alpine binary suites removed (static check kept); kube-linter lints the chart without the third-party subchart; tools cache keyed on `src/go.mod`
- **delivery:** `main.go` findings fixed (error handling, `%w`, server timeouts, two documented `#nosec`); chart: zero-downtime settings on (RollingUpdate 0/1, PDB, anti-affinity), arm64 preferred affinity, resources, ServiceAccount, NetworkPolicy (Envoy-only ingress)
- **guardrails:** `docs/CI.md#gating` and `.github/workflows/AGENTS.md` gating rules; `docs/CI.md#gosec-exceptions`; e2e suites unchanged to preserve behavior
- **breaking changes:** app pods only accept traffic from the release's Envoy proxy (NetworkPolicy)
- **Action needed:** none

### 2026-10-21 - [#1](https://github.com/YoyoBesser/echo-pong/pull/1) - Home assignment init: CI/CD skeleton, container, chart, e2e and security scans

**Intent:** Put CI guardrails in place before touching app code.

**Result:** Every PR builds amd64 and arm64 images and static binaries, then runs black-box CLI, API and live-minikube e2e on the images and CLI/API e2e on the binaries on ubuntu and alpine.

- **authors:** YoyoBesser
- **dependencies:** Go app moved to `src/` (unchanged); base images `gcr.io/distroless/static-debian13:nonroot` + `busybox:musl`; chart dependency `gateway-helm` 1.9.2; CI tool pins in `.github/actions/install-ci-tools` (golangci-lint v2.15.0, helm v4.3.1, kubeconform v0.8.0, kube-linter v0.8.3, minikube v1.39.0, k8s 1.35.0)
- **workflows:** weekly `cleanup.yml` GHCR retention (dry-run on demand, multi-arch aware); reusable `scan-source.yml` / `scan-image.yml` shared by CI (non-blocking) and release (blocking gate before `publish`); `common-ci.yml` on every commit (no path filter): actionlint, ruff, pytest, doc links, blocking repo secret scan (trivy fs + gitleaks, reusable `scan-repo.yml`, also in the release gate); one multi-arch buildx build pushed to GHCR as `<sha>`, BuildKit registry cache `<branch-slug>-cache` (fallback `main-cache`); `.github/scripts/act.sh` runs workflows locally against a local registry; `scripts/minikube-up.sh` runs the app on minikube behind the real Gateway address (`--test` runs every suite); `actions/cache` for tool binaries, Go, minikube, trivy DB and kubeconform schemas;  Tests + Security summary tables in every workflow (`record-results`, `summarize-results`); new `app-ci.yml` (golangci-lint, go vet, staticcheck, gosec, govulncheck, trivy image scan, native arch build matrix, per-arch `e2e-tests`: CLI, API, binary on ubuntu/alpine, then minikube, in one job), `helm-ci.yml` (helm lint, kubeconform, kube-linter), `release.yml` and `cd.yml` skeletons; shared actions `gather-metadata`, `install-ci-tools`
- **delivery:** new `src/Dockerfile` (cross-compiled, non-root UID 65532, busybox shell); static linux binaries extracted from the image as CI artifacts; basic chart `helm/echo-pong` with Envoy Gateway subchart and Gateway API routing, hardened securityContext (non-root 65532, read-only root FS, drop ALL, no escalation, seccomp); TODO spots (off) for rolling update, PDB, anti-affinity
- **guardrails:** all checks failing on original code soft-fail for now (`docs/CI.md#soft-fail`); `check_doc_links.py` in common-ci fails on broken or non-root-relative doc links; blocking trivy config gate on 8 README-traced KSV IDs (`helm/.trivy-ksv-gate`); PSA `restricted` enforced on the minikube e2e namespace; `.github/workflows/AGENTS.md` workflow conventions; README-traced kube-linter policy; e2e suites in `src/test/e2e`; `AGENTS.md` comment and changelog rules; `docs/TASKS.md` maps each README requirement (by line) to how we meet it
- **breaking changes:** `main.go`/`go.mod` moved from repo root to `src/`
- **Action needed:** run: helm dependency build helm/echo-pong && (cd .github && uv sync)
