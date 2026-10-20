# .github/workflows/AGENTS.md

Rules for every workflow in this directory. Repo-wide rules: [../../AGENTS.md](../../AGENTS.md). Background: [docs/CI.md](../../docs/CI.md).

## Shape

- First job: `metadata` ([`gather-metadata`](../actions/gather-metadata/action.yml)). Last job: `summary` (`needs:` every job, `if: always()`), which runs [`summarize-results`](../actions/summarize-results/action.yml) with `order:` listing job ids in display order.
- Tools come only from [`install-ci-tools`](../actions/install-ci-tools/action.yml) (`suite: app|helm|minikube|scan|github`). Never pin a tool version in a workflow. Actions are pinned by major tag (`@v7`), or by exact tag when upstream publishes no major tag (`astral-sh/setup-uv@v10.3.0`).
- Every pin, whether a tool in the pins block or an action `uses:`, carries a trailing `# latest: <release page URL> (checked YYYY-MM-DD)`. When you bump a pin or re-check it, update that date.
- Python under `.github/` runs only through uv: `uv run --locked` in `.github/`. The Python version comes from `.github/.python-version`, and dependencies from `pyproject.toml` + `uv.lock`. Any Python change must keep `ruff check`, `ruff format --check` and pytest at 100% coverage passing ([docs/CI.md#github-ci](../../docs/CI.md#github-ci)).
- Arch matrices use native runners: `amd64` on `ubuntu-latest`, `arm64` on `ubuntu-24.04-arm`.
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

Cell values: `✅ pass`, `❌ fail` (blocking), `⚠️ fail (non-blocking)` (failed under `continue-on-error`), `⏭️ skipped`, `🚫 cancelled`.

## Soft-fail

`continue-on-error: true` is allowed only on check steps, with a `TODO` comment linking [docs/CI.md#soft-fail](../../docs/CI.md#soft-fail). The summary still shows those failures as `⚠️`.

## Before pushing

- `actionlint` is clean.
- The job runs under act where possible ([docs/LOCAL-TESTING.md#ci](../../docs/LOCAL-TESTING.md#ci)). Artifact upload/download doesn't work under act, so the summary tables only render on GitHub.
- [docs/CHANGELOG.md](../../docs/CHANGELOG.md) has an entry for the change.
