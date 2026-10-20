# Local testing

## CI

Workflows run locally with [act](https://github.com/nektos/act), which runs each job in a Docker container.

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
CHART_REF=oci://ghcr.io/yoyobesser/charts/echo-pong src/test/e2e/minikube-e2e.sh  # a released chart instead of in-repo
```

Profile `echo-pong-e2e` by default (`MINIKUBE_PROFILE` overrides it). Run the script directly, not through act: minikube under act would publish the API server port on the host daemon, which the act job container can't reach.

## Binary e2e

Same check as CI's [binary e2e](CI.md#binary-e2e): pull the binary out of the image, put it on a stock distro, run both suites.

```sh
docker buildx build --platform linux/arm64 --load -t echo-pong:ci src/
id=$(docker create echo-pong:ci) && mkdir -p dist && docker cp "$id:/usr/local/bin/ping-pong-app" dist/ && docker rm "$id"
file dist/ping-pong-app                                   # must say "statically linked"
docker build -f src/test/e2e/binary.Dockerfile --build-arg BASE=alpine:latest -t echo-pong:bin dist/
cd src && E2E_IMAGE=echo-pong:bin go test -tags e2e -count=1 -v ./test/e2e
```

Use `BASE=ubuntu:latest` for glibc, and `--platform linux/amd64` on both builds for x86 under emulation. `dist/` is gitignored.

## GitHub CI

Same checks as CI's [GitHub CI](CI.md#github-ci):

```sh
actionlint
cd .github && uv run --locked ruff check . && uv run --locked ruff format --check . && uv run --locked pytest
```

uv picks Python 3.14 from `.github/.python-version`. Use uv ≥ 0.13 (CI pins 0.13.4). After editing dependencies in `pyproject.toml`, run `uv lock` and commit `uv.lock`.
