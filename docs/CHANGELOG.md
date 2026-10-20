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
- **dependencies:** none | what changed in go.mod, Chart.lock, base images or pinned tools
- **workflows:** none | what changed in `.github/workflows/`, `.github/actions/` or CI
- **delivery:** none | what changed in the image (`src/Dockerfile`) or chart (`helm/`)
- **guardrails:** none | new or changed tests, linters, policies or AGENTS rules
- **breaking changes:** none | incompatible behaviour or config
- **Action needed:** none
```

---

### 2026-10-20 - [#1](https://github.com/YoyoBesser/echo-pong/pull/1) - Home assignment init: CI skeleton, container, chart, e2e

**Intent:** Put CI guardrails in place before touching app code.

**Result:** Every PR builds amd64 and arm64 images and runs black-box CLI, API and live-minikube e2e against them.

- **authors:** YoyoBesser
- **dependencies:** Go app moved to `src/` (unchanged); base images `gcr.io/distroless/static-debian13:nonroot` + `busybox:musl`; chart dependency `gateway-helm` 1.9.2; CI tool pins in `.github/actions/install-ci-tools` (golangci-lint v2.15.0, helm v4.3.1, kubeconform v0.8.0, kube-linter v0.8.3, minikube v1.39.0, k8s 1.35.0)
- **workflows:** new `app-ci.yml` (lint, native arch build matrix, per-arch parallel e2e), `helm-ci.yml` (helm lint, kubeconform, kube-linter), `release.yml` and `cd.yml` skeletons; shared actions `gather-metadata`, `install-ci-tools`
- **delivery:** new `src/Dockerfile` (cross-compiled, non-root UID 65532, busybox shell); basic chart `helm/echo-pong` with Envoy Gateway subchart and Gateway API routing
- **guardrails:** golangci-lint and chart checks soft-fail for now (`docs/CI.md#soft-fail`); README-traced kube-linter policy; e2e suites in `src/test/e2e`; `AGENTS.md` comment and changelog rules
- **breaking changes:** `main.go`/`go.mod` moved from repo root to `src/`
- **Action needed:** run: helm dependency build helm/echo-pong
