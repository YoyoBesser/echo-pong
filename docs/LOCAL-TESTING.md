# Local testing

## Contents

- [CI](#ci)
  - [Setup](#setup)
  - [Run](#run)
  - [Gotchas](#gotchas)
- [E2E](#e2e)
- [Minikube e2e](#minikube-e2e)
- [Common CI](#common-ci)
- [Act wrapper](#act-wrapper)
- [Minikube up](#minikube-up)

## CI

Workflows run locally with [act](https://github.com/nektos/act), which runs each job in a Docker container. Use the [act wrapper](#act-wrapper) instead of calling act directly.

### Setup

```sh
brew install act      # Docker must be running
```

The repo's [`.actrc`](../.actrc) maps `ubuntu-latest` to `catthehacker/ubuntu:act-latest`, so everyone gets the same runner image. On Apple silicon act pulls the `linux/arm64` variant and runs it natively. GitHub's hosted runners are `amd64`, so arch-specific bugs can still differ.

### Run

Always pass `-W`. Every workflow has a `metadata` job, so `-j metadata` alone runs it in every workflow at once.

```sh
act -l                                                   # list workflows + jobs
act push -W .github/workflows/app-ci.yml                 # full app CI, as on push to main
act push -W .github/workflows/app-ci.yml -j lint         # one job (its needs run first)
act push -W .github/workflows/helm-ci.yml                # chart CI
```

`pull_request` needs an event payload, or `github.head_ref` and the PR head SHA are empty:

```sh
jq -n --arg ref "$(git branch --show-current)" --arg sha "$(git rev-parse HEAD)" \
  '{pull_request: {head: {ref: $ref, sha: $sha}, base: {ref: "main"}}}' > /tmp/pr.json
act pull_request -W .github/workflows/app-ci.yml -e /tmp/pr.json
```

### Gotchas

- act ignores `paths:` filters, so `-W` picks the workflow, not what changed.
- act runs the working tree, including uncommitted changes. `github.sha` is still the `HEAD` commit, so metadata reports `HEAD`.
- The act runner image is smaller than GitHub's. For example, it has no `gh` CLI. Steps must not assume preinstalled tools beyond `git`, `curl` and `jq`.
- Artifact handoff (`build` to `e2e-tests`) doesn't work under act (still broken in v0.2.89): its artifact server doesn't speak the `upload-artifact@v7` protocol. Run e2e directly instead, see [E2E](#e2e).
- No jobs need secrets yet. When one does, pass it with `-s NAME=value` (for example `-s GITHUB_TOKEN="$(gh auth token)"`). Never commit a `.secrets` file.

## E2E

Build the image for one arch and run the suites from [CI.md#e2e-tests](CI.md#e2e-tests) against it:

```sh
docker buildx build --platform linux/arm64 --load -t echo-pong:ci src/
cd src && E2E_IMAGE=echo-pong:ci go test -tags e2e -count=1 -v ./test/e2e                 # both suites
cd src && E2E_IMAGE=echo-pong:ci go test -tags e2e -count=1 -v -run '^TestAPI$' ./test/e2e  # one suite
```

On Apple silicon, `--platform linux/amd64` builds and runs the amd64 image under emulation. It's slower, but it works.

The tests pass the secret with `docker cp` into a created container, never a bind mount. Under act, the docker CLI runs in a job container but talks to the host daemon, so a bind-mount path from the job container doesn't exist on the host. `docker cp` streams the file through the CLI, so it works the same everywhere.

## Minikube e2e

Runs the same flow as CI's [minikube e2e](CI.md#minikube-e2e) job. Needs Docker, `minikube`, `helm`, `kubectl` and Go.

```sh
docker buildx build --platform linux/arm64 --load -t echo-pong:ci src/
src/test/e2e/minikube-e2e.sh                          # minikube default k8s version
K8S_VERSION=1.35.0 src/test/e2e/minikube-e2e.sh       # match CI's pin
KEEP_CLUSTER=1 src/test/e2e/minikube-e2e.sh           # leave cluster up to poke at it
```

Profile `echo-pong-e2e` by default (`MINIKUBE_PROFILE` overrides it). Run the script directly, not through act: minikube under act would publish the API server port on the host daemon, which the act job container can't reach.

## Common CI

Same checks as CI's [Common CI](CI.md#common-ci), except the secret scan:

```sh
actionlint
cd .github && uv run --locked ruff check . && uv run --locked ruff format --check . && uv run --locked pytest
```

uv picks Python 3.14 from `.github/.python-version`. Use uv ≥ 0.13 (CI pins 0.13.4). After editing dependencies in `pyproject.toml`, run `uv lock` and commit `uv.lock`.

## Act wrapper

[`.github/scripts/act.sh`](../.github/scripts/act.sh) runs a workflow, or one job, with the local stand-ins that make it behave like GitHub:

```sh
.github/scripts/act.sh app-ci                 # whole workflow, push event
.github/scripts/act.sh app-ci build           # one job (act runs its needs first)
.github/scripts/act.sh app-ci e2e-tests --arch arm64
.github/scripts/act.sh helm-ci --pr           # pull_request event built from current branch + HEAD
.github/scripts/act.sh app-ci lint -- -v      # extra act flags after --
```

What it sets up:

- **Local registry** (`registry:3.1.2` on `localhost:5000`, container `act-registry`) as the GHCR stand-in, removed on exit (`KEEP_REGISTRY=1` keeps it). `--var CI_IMAGE=localhost:5000/echo-pong` makes `gather-metadata` push and pull there, so a local run never touches the real GHCR.
- **buildx on the host network**: under act (`env.ACT`), `setup-buildx-action` uses `driver-opts: network=host`, so the BuildKit container can reach that registry.
- **Event payload**: `-W` for the workflow, a `pull_request` payload from git for `--pr`, and `--matrix arch:<arch>` for `--arch`.
- **Token**: `GITHUB_TOKEN` from `gh auth token`. act needs it to clone remote actions; with a dummy token they're silently skipped. The local registry accepts it as a login.

Still not possible under act: artifact upload/download (act's artifact server doesn't speak v7). Those steps are non-fatal under act (`continue-on-error: ${{ !!env.ACT }}`), so jobs after `build` that need artifacts (`e2e-tests`, `summary`) won't have them. Run e2e directly per [E2E](#e2e).

## Minikube up

[`scripts/minikube-up.sh`](../scripts/minikube-up.sh) runs the app on a local minikube, reachable the way it would be in a cloud cluster: through the Envoy Gateway's own address, not a port-forward.

```sh
scripts/minikube-up.sh                 # build the image from src/ (this machine's arch), deploy, tunnel
scripts/minikube-up.sh --tag <tag>     # use ghcr.io/yoyobesser/echo-pong:<tag> instead, e.g. a commit SHA from CI
scripts/minikube-up.sh --test          # deploy, then run every e2e suite and exit with the result
scripts/minikube-up.sh --port 80       # listener on :80 (minikube tunnel asks for sudo below 1024)
scripts/minikube-up.sh --status        # what's running + URL, token, curls again (changes nothing)
scripts/minikube-up.sh --down          # delete the cluster
```

What it does:

1. Builds the image (`echo-pong:dev-<short-sha>[-dirty]`) or pulls the GHCR tag. The package is public, so no login is needed. The image is loaded into minikube, so the cluster needs no pull secret.
2. Starts minikube (profile `echo-pong-dev`) on the CI `k8s-version` pin, read from `install-ci-tools`.
3. Deploys the local chart through the same steps as the [minikube e2e](CI.md#minikube-e2e): namespace with [PSA `restricted`](HELM.md#pod-security-admission), auth Secret, `helm upgrade --install`. They're shared via [`scripts/lib/minikube.sh`](../scripts/lib/minikube.sh). The difference is `gateway.serviceType=LoadBalancer` and `gateway.port` (default 8080).
4. Runs `minikube tunnel`, which gives the Envoy LoadBalancer Service the external IP `127.0.0.1`. The Gateway then reports that address as `Programmed`.
5. Prints the URL, the token and ready-to-paste curls, then keeps the tunnel in the foreground. Ctrl-C stops the tunnel; the cluster stays up for a quick rerun.

With `--test`, it runs the same suites as CI's `e2e-tests` job for the local arch instead of holding the tunnel: CLI and API e2e against the image, the static-binary check, and API e2e through the live Gateway URL. It prints a pass/fail table and exits non-zero if any suite failed.

`--status` checks the cluster, the release image, pod readiness, whether a tunnel is running, the Gateway address and `/health`, and then prints the same URL, token and curls as a normal run. It exits 0 only if the app answers through the tunnel. If the tunnel is down, it says so: rerun the script to reconnect.
