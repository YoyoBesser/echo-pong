# Docs

Start here. The assignment itself is the repo [README](../README.md). Requirement-by-requirement tracking is in [TASKS.md](TASKS.md).

## Layout vs the README

The README asks for a `Dockerfile` and `k8s/` manifests (L100, L101). This repo has:

- **`src/Dockerfile`**, next to the Go app it builds (`src/`), with the build context scoped to that directory. See [CONTAINER.md](CONTAINER.md).
- **`helm/echo-pong/`**, a Helm chart instead of raw `k8s/` YAML. One chart renders every manifest (Deployment, Service, ServiceAccount, PDB, NetworkPolicy, optional HPA, Gateway API objects) from one values file, with Envoy Gateway as a pinned subchart. See [HELM.md](HELM.md).

## Reference docs

| Doc | Covers |
|---|---|
| [EXPLAIN.md](EXPLAIN.md) | Answers to the README's "you will be asked to explain" list |
| [TASKS.md](TASKS.md) | Every README requirement, by line, and how it's met |
| [CI.md](CI.md) | CI workflows: gating, lint, scans, build, e2e, summary tables, tool pins and caches |
| [RELEASE.md](RELEASE.md) | Versioning, the release pipeline, signing, chart and binaries |
| [GITHUB.md](GITHUB.md) | Map of `.github/`: workflow call graphs, actions, scripts |
| [CONTAINER.md](CONTAINER.md) | Image: distroless + busybox base, cross-compile, Go toolchain, version stamp, non-root |
| [HELM.md](HELM.md) | Chart: values, Envoy Gateway, security context, zero downtime, scaling, network policy |
| [LOCAL-TESTING.md](LOCAL-TESTING.md) | Running CI with act, e2e, and the app on minikube (`scripts/minikube-up.sh`) |
| [CHANGELOG.md](CHANGELOG.md) | One entry per PR: what changed, why, and what to do after pulling |

Conventions for editing code and docs: [AGENTS.md](../AGENTS.md) and [docs/AGENTS.md](AGENTS.md).
