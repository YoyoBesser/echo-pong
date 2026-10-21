# GitHub

Map of `.github/`: what each workflow and composite action does, and who calls what. Behaviour and rationale live in [CI.md](CI.md).

## Contents

- [Call graph](#call-graph)
- [Workflows](#workflows)
- [Actions](#actions)
- [Scripts](#scripts)

## Call graph

One box per workflow, listing the local actions and reusable workflows it `uses:`, in job order. Reusable workflows get their own box too.

```mermaid
flowchart TB
  subgraph g0[.github/workflows/app-ci.yml]
    direction LR
    g0n0[.github/actions/gather-metadata]
    g0n1[.github/actions/install-ci-tools]
    g0n2[.github/actions/record-results]
    g0n3[.github/workflows/scan-source.yml]
    g0n4[.github/workflows/scan-image.yml]
    g0n5[.github/actions/summarize-results]
    g0n0 --> g0n1 --> g0n2 --> g0n3 --> g0n4 --> g0n5
  end
  subgraph g1[.github/workflows/helm-ci.yml]
    direction LR
    g1n0[.github/actions/gather-metadata]
    g1n1[.github/actions/install-ci-tools]
    g1n2[.github/actions/record-results]
    g1n3[.github/actions/summarize-results]
    g1n0 --> g1n1 --> g1n2 --> g1n3
  end
  subgraph g2[.github/workflows/common-ci.yml]
    direction LR
    g2n0[.github/actions/gather-metadata]
    g2n1[.github/actions/install-ci-tools]
    g2n2[.github/actions/record-results]
    g2n3[.github/workflows/scan-repo.yml]
    g2n4[.github/actions/summarize-results]
    g2n0 --> g2n1 --> g2n2 --> g2n3 --> g2n4
  end
  subgraph g3[.github/workflows/release.yml]
    direction LR
    g3n0[.github/actions/gather-metadata]
    g3n1[.github/workflows/scan-source.yml]
    g3n2[.github/workflows/scan-repo.yml]
    g3n3[.github/workflows/scan-image.yml]
    g3n4[.github/actions/install-ci-tools]
    g3n5[.github/actions/record-results]
    g3n6[.github/actions/summarize-results]
    g3n0 --> g3n1 --> g3n2 --> g3n3 --> g3n4 --> g3n5 --> g3n6
  end
  subgraph g4[.github/workflows/cd.yml]
    direction LR
    g4n0[.github/actions/gather-metadata]
    g4n1[.github/actions/summarize-results]
    g4n0 --> g4n1
  end
  subgraph g5[.github/workflows/cleanup.yml]
    direction LR
    g5n0[.github/actions/gather-metadata]
    g5n1[.github/actions/install-ci-tools]
    g5n2[.github/actions/summarize-results]
    g5n0 --> g5n1 --> g5n2
  end
  subgraph g6[.github/workflows/scan-source.yml]
    direction LR
    g6n0[.github/actions/install-ci-tools]
    g6n1[.github/actions/record-results]
    g6n0 --> g6n1
  end
  subgraph g7[.github/workflows/scan-image.yml]
    direction LR
    g7n0[.github/actions/install-ci-tools]
    g7n1[.github/actions/record-results]
    g7n0 --> g7n1
  end
  subgraph g8[.github/workflows/scan-repo.yml]
    direction LR
    g8n0[.github/actions/install-ci-tools]
    g8n1[.github/actions/record-results]
    g8n0 --> g8n1
  end
  g0 ~~~ g1 ~~~ g2 ~~~ g3 ~~~ g4 ~~~ g5 ~~~ g6 ~~~ g7 ~~~ g8
```

## Workflows

| Workflow | Trigger | Jobs | Calls |
|---|---|---|---|
| [`app-ci.yml`](../.github/workflows/app-ci.yml) | PR/push to `main` on `src/**`, `helm/**`, itself, `.github/actions/**`; manual | `metadata`, `lint`, `test`, `build`, `scan-source`, `scan-image`, `e2e-tests` (amd64, arm64), `summary` | `scan-source.yml`, `scan-image.yml`; all four actions; `extract-binary.sh`, `minikube-e2e.sh` |
| [`helm-ci.yml`](../.github/workflows/helm-ci.yml) | PR/push to `main` on `helm/**`, itself, `.github/actions/**`; manual | `metadata`, `lint`, `summary` | all four actions |
| [`common-ci.yml`](../.github/workflows/common-ci.yml) | every PR/push to `main` (no path filter); manual | `metadata`, `lint`, `test`, `doc-links`, `scan-repo`, `summary` | `scan-repo.yml`; all four actions; `check_doc_links.py` |
| [`release.yml`](../.github/workflows/release.yml) | push of tag `vX.Y.Z` | `metadata`, `image`, `scan-source`, `scan-repo`, `scan-image`, `publish`, `binaries`, `github-release`, `summary` | all three scans; all four actions |
| [`cd.yml`](../.github/workflows/cd.yml) | manual, input `version` | `metadata`, `deploy`, `verify`, `summary` | `gather-metadata`, `summarize-results` |
| [`cleanup.yml`](../.github/workflows/cleanup.yml) | weekly (Mon 03:17 UTC); manual with `dry-run`, `max-age-days` | `metadata`, `cleanup`, `summary` | `gather-metadata`, `install-ci-tools`, `summarize-results`; `ghcr_cleanup.py` |
| [`scan-source.yml`](../.github/workflows/scan-source.yml) | `workflow_call` | `scan-source` (gosec, govulncheck) | `install-ci-tools` (`app`), `record-results` |
| [`scan-image.yml`](../.github/workflows/scan-image.yml) | `workflow_call`, inputs `image`, `registry` | `scan-image` (amd64, arm64) | `install-ci-tools` (`scan`), `record-results`; `trivy-image.sh` |
| [`scan-repo.yml`](../.github/workflows/scan-repo.yml) | `workflow_call` | `scan-repo` (trivy fs, gitleaks) | `install-ci-tools` (`repo`), `record-results` |

`cd.yml` jobs are placeholders. Scheduled and manual runs only start once the workflow is on `main`.

Gotcha: `app-ci.yml`'s path filter doesn't include the `scan-*.yml` files. A change to only a reusable scan doesn't run app CI.

## Actions

| Action | Does | Inputs | Used by |
|---|---|---|---|
| [`gather-metadata`](../.github/actions/gather-metadata/action.yml) | Branch, SHA, commit message, trigger reason, branch slug, image ref and registry ([CI.md#gather-metadata](CI.md#gather-metadata)) | `image` (registry override) | `metadata` job of every top-level workflow |
| [`install-ci-tools`](../.github/actions/install-ci-tools/action.yml) | Pinned, checksum-verified, cached tools per suite ([CI.md#tool-pins](CI.md#tool-pins)) | `suite` (`app`, `helm`, `minikube`, `scan`, `repo`, `github`), `k8s-version` | every job that runs a tool, and `summarize-results` |
| [`record-results`](../.github/actions/record-results/action.yml) | Uploads one `kind\|check\|outcome\|conclusion` row per check as an artifact ([CI.md#build-summary](CI.md#build-summary)) | `rows`, `scope` | every test and scan job |
| [`summarize-results`](../.github/actions/summarize-results/action.yml) | Renders the Tests and Security tables into the run summary with `render.py` | `order` | `summary` job of every top-level workflow |

## Scripts

| Script | Does | Called by |
|---|---|---|
| [`extract-binary.sh`](../.github/scripts/extract-binary.sh) | Copies one arch's binary out of the pushed image, fails unless static | `app-ci.yml` `build` |
| [`minikube-e2e.sh`](../src/test/e2e/minikube-e2e.sh) | Deploys the chart to minikube, runs `TestAPI` through the Gateway | `app-ci.yml` `e2e-tests`, locally |
| [`trivy-image.sh`](../.github/scripts/trivy-image.sh) | trivy image scan per arch, govulncheck-filtered | `scan-image.yml` |
| [`check_doc_links.py`](../.github/scripts/check_doc_links.py) | Checks doc links and anchors ([CI.md#doc-links](CI.md#doc-links)) | `common-ci.yml` `doc-links` |
| [`ghcr_cleanup.py`](../.github/scripts/ghcr_cleanup.py) | GHCR retention policy ([CI.md#image-cleanup](CI.md#image-cleanup)) | `cleanup.yml` |
| [`render.py`](../.github/actions/summarize-results/render.py) | Renders result rows as Markdown tables | `summarize-results` |
| [`act.sh`](../.github/scripts/act.sh) | Runs a workflow locally with act ([LOCAL-TESTING.md#act-wrapper](LOCAL-TESTING.md#act-wrapper)) | developers |
