# .github/workflows/AGENTS.md

Rules for every workflow in this directory. Repo-wide rules: [../../AGENTS.md](../../AGENTS.md). Background: [docs/CI.md](../../docs/CI.md).

## Shape

- First job: `metadata` ([`gather-metadata`](../actions/gather-metadata/action.yml)). Last job: `summary` (`needs:` every job, `if: always()`), which runs [`summarize-results`](../actions/summarize-results/action.yml) with `order:` listing job ids in display order.
- Tools come only from [`install-ci-tools`](../actions/install-ci-tools/action.yml) (`suite: app|helm|minikube|scan|github`). Never pin a tool version in a workflow. Actions are pinned by major tag (`@v7`), or by exact tag when upstream publishes no major tag (`astral-sh/setup-uv@v10.3.0`).
- Every pin, whether a tool in the pins block or an action `uses:`, carries a trailing `# latest: <release page URL> (checked YYYY-MM-DD)`. When you bump a pin or re-check it, update that date.
- Python under `.github/` runs only through uv: `uv run --locked` in `.github/`. The Python version comes from `.github/.python-version`, and dependencies from `pyproject.toml` + `uv.lock`. Any Python change must keep `ruff check`, `ruff format --check` and pytest at 100% coverage passing ([docs/CI.md#common-ci](../../docs/CI.md#common-ci)).
- Arch matrices use native runners: `amd64` on `ubuntu-latest`, `arm64` on `ubuntu-24.04-arm`.
- Images are built once for both arches and go to GHCR as the multi-arch `<image>:<sha>` (full commit SHA). The registry cache is `<branch-slug>-cache`, falling back to `main-cache` ([docs/CI.md#image-tags](../../docs/CI.md#image-tags)). Image names, registry hosts and slugs come from `gather-metadata` outputs, never hand-built.
- Steps that can't work under act (artifact upload/download) set `continue-on-error: ${{ !!env.ACT }}`: non-fatal locally, blocking on GitHub. Run workflows locally through `.github/scripts/act.sh` ([docs/LOCAL-TESTING.md#act-wrapper](../../docs/LOCAL-TESTING.md#act-wrapper)).
- Default `permissions: contents: read`. A job that pushes images adds `packages: write`. A job that only pulls adds `packages: read`.
- Security scans are never inlined. Call [`scan-source.yml`](scan-source.yml) / [`scan-image.yml`](scan-image.yml) / [`scan-repo.yml`](scan-repo.yml), so CI and release run identical checks ([docs/CI.md#reusable-scans](../../docs/CI.md#reusable-scans)).
- Inside reusable workflows, log in with `${{ github.token }}`, not `secrets.GITHUB_TOKEN`. act doesn't pass secrets into called workflows.
- Untrusted values (`head_ref`, commit messages, inputs) go through `env:`, never inline `${{ }}` in `run:` ([docs/CI.md#script-injection](../../docs/CI.md#script-injection)).

## Checks and the summary tables

Every run summary ends with two tables, **Tests** and **Security**: rows are checks, columns are scopes (`all`, `amd64`, `arm64`). To keep them complete and consistent:

- Every check step has an `id` and a `name` of the form `tool (purpose)`, e.g. `gosec (SAST)`.
- Every job that runs checks ends with one [`record-results`](../actions/record-results/action.yml) step, `if: always()`, with `scope: ${{ matrix.arch }}` in arch matrices (default `all`). One row per check:
  ```yaml
  rows: |
    security|gosec (SAST)|${{ steps.gosec.outcome }}|${{ steps.gosec.conclusion }}
  ```
- Row kind:
  - `tests`: does it build and behave correctly? Linters, `go vet`, staticcheck, e2e suites, `helm lint`/`template`, kubeconform, kube-linter, static-binary check.
  - `security`: could it ship a vulnerability or exposure? gosec (SAST), govulncheck (SCA), trivy image, trivy config, secret scanning.
- Check names are identical across jobs and workflows, so one check is one row.
- Placeholder steps (`echo "TODO ..."`) are not recorded.

Cell values: `✅ pass`, `❌ fail`, `⏭️ skipped` (an earlier check failed fast), `🚫 cancelled`. (`⚠️ fail (non-blocking)` exists for `continue-on-error` steps, which checks must not use.)

## Gating

Every check gates ([docs/CI.md#gating](../../docs/CI.md#gating)):

- No `continue-on-error` on check steps. The only exceptions are act-only artifact steps (`${{ !!env.ACT }}`) and the summary plumbing.
- Lint, unit, scan and chart-check jobs fail fast: plain sequential steps, so the first failure stops the job.
- E2E suites all run: every suite step after the first gets `if: ${{ !cancelled() }}`, so the job fails at the end with every failure visible.

## Before pushing

- `actionlint` is clean.
- The job runs under act where possible ([docs/LOCAL-TESTING.md#ci](../../docs/LOCAL-TESTING.md#ci)). Artifact upload/download doesn't work under act, so the summary tables only render on GitHub.
- [docs/CHANGELOG.md](../../docs/CHANGELOG.md) has an entry for the change.
