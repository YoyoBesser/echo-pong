# Plan: finalize the skeleton (2026-10-21)

Close the gaps between the README requirements and the skeleton on branch `feat/yonatan.besser/home-assignment-init` (PR #1). We take the items one by one, in the order below.

Ground rules (from this PR's scope):

- Don't fix the exercise's original files (`src/main.go`, `src/go.mod`). App-code items wait for a follow-up PR.
- New checks that fail on original code or the basic chart are soft-fail (`docs/CI.md#soft-fail`).
- Each item that ships updates `docs/TASKS.md` (tick or add bullets), `docs/CHANGELOG.md` (PR #1 entry), and the reference docs its code comments link to.
- Fail fast locally (act wrapper, minikube script). Run full CI only when the branch is done.

Status: `todo` / `doing` / `done`.

| # | README | Action | Status |
|---|---|---|---|
| 1 | L49, L53, L83 | Implement now | done |
| 2 | L51 | Refactor scanning into reusable pieces, used by CI and release | done |
| 3 | L52 | `github-ci.yml` becomes `common-ci.yml`, with repo-wide scanning | done |
| 4 | L56 | TODO spot in chart | todo |
| 5 | L56 | TODO spot for rollout verification | todo |
| 6 | L56 | Later | — |
| 7 | L57 | Later | — |
| 8 | L58 | Later | — |
| 9 | L59 | Later | — |
| 10 | L64 | Later | — |
| 11 | L84 | Later | — |
| 12 | L84 | Later | — |
| 13 | L94, L116 | Separate cleanup workflow | todo |
| 14 | L101, L103 | Later | — |
| 15 | L90, L108 | Later | — |
| 16 | L91, L109 | Later | — |
| 17 | L93, L110 | Later | — |
| 18 | L113 | Later | — |
| 19 | L92, L114 | Later | — |
| 20 | L115 | Later | — |

## 1. Chart securityContext (implement now)

**Requirement:** README L49 "No containers running as root", L53 "Proper filesystem isolation", L83 "Container Security".

**Do:**
- In `helm/echo-pong/templates/deployment.yaml`, add a pod `securityContext`: `runAsNonRoot: true`, `runAsUser`/`runAsGroup`/`fsGroup: 65532` (matching the image's `USER`), and `seccompProfile: RuntimeDefault`.
- Add a container `securityContext`: `allowPrivilegeEscalation: false`, `readOnlyRootFilesystem: true`, `capabilities.drop: [ALL]`, `privileged: false`.
- Make both overridable from `values.yaml` (`podSecurityContext`, `securityContext`), with these as the defaults.
- If the app needs a writable path, mount an `emptyDir` for it. Expected: none needed, since the secret volume is read-only and the app writes nothing.

**Done when:**
- `trivy config` passes the README gate (KSV-0001, -0003, -0012, -0014).
- kube-linter's `run-as-non-root` and `no-read-only-root-fs` pass.
- The minikube e2e still passes with the read-only root FS.
- If the gate is clean, drop `continue-on-error` from the `trivy config` step (it becomes the first blocking chart check).

## 2. Reusable scanning (CI + release)

**Requirement:** README L51 "No critical/high vulnerabilities should be released to production", L87 "release prevention".

**Do:**
- Move the image scan into a reusable workflow, `.github/workflows/scan-image.yml` (`on: workflow_call`). Inputs: `image` (ref incl. tag/digest) and `platforms`. It runs `trivy-image.sh` per platform and records results.
- Move source SAST/SCA (gosec, govulncheck) into a reusable workflow, or a composite action, `scan-source`.
- `app-ci.yml` calls both instead of having inline steps.
- `release.yml`:
  1. Build and push the multi-arch image under its commit SHA.
  2. Call `scan-image` on that digest.
  3. Retag to `vX.Y.Z` only after the scan passes.

  A failed scan means no version tag, so nothing is released.

**Done when:** CI and release run the identical scan definitions; release has a job dependency `scan → publish`; docs `CI.md#image-scan` and a release section describe the gate.

**Open:** a reusable workflow versus a composite action for each scan. The reusable workflow keeps scan jobs visible as their own jobs in both callers. Recording summary results across a `workflow_call` boundary needs checking.

## 3. `common-ci.yml` with repo-wide scanning

**Requirement:** README L52 "No secrets in codebase".

**Do:**
- Rename `github-ci.yml` to `common-ci.yml`, with no path filter, so it runs on every commit.
- Fold `docs-ci.yml` into it (doc links), then delete `docs-ci.yml`.
- Jobs: `lint` (actionlint, ruff), `test` (pytest 100%), `doc-links`, `repo-scan`.
- `repo-scan`: secret scanning over the whole repo. Proposed: `trivy fs --scanners secret` (trivy is already pinned and cached), plus `gitleaks` over git history, since trivy only sees the working tree. Decide when implementing.
- Remove the `secret-scan` placeholder job from `app-ci.yml`.
- Path-filter cost: actionlint/ruff/pytest then run on every commit. They take about 1 min, which is acceptable. If not, keep them as path-filtered jobs within the same workflow via `dorny/paths-filter` or similar.

**Done when:** a planted fake secret in a test branch fails `repo-scan`; summary shows it under **Security**; docs/CI.md updated (workflow split table, new section).

## 4. TODO: zero-downtime rollout settings in chart

**Requirement:** README L56 "Zero-downtime deployments server must be available and ready at all times".

**Do (TODO spot only):**
- In `values.yaml` and `deployment.yaml`, add commented or disabled placeholders for:
  - `strategy.rollingUpdate` (`maxUnavailable: 0`, `maxSurge: 1`).
  - A `PodDisruptionBudget` template behind `pdb.enabled: false`.
  - Pod anti-affinity (preferred, by hostname) behind a value.
- Each placeholder gets a `TODO` comment linking a `docs/HELM.md#zero-downtime` section that states the requirement.

## 5. TODO: verify zero-downtime rollout

**Requirement:** README L56.

**Do (TODO spot only):**
- Add a placeholder step after `minikube e2e` in `app-ci.yml` (`echo "TODO ..."`, not recorded in the summary), with a TODO comment linking a doc section.
- Intended design, recorded in that section: during `helm upgrade` to a changed pod template, poll `/health` and `/ping` through the Gateway, and fail on any non-2xx or connection error.

## 6–12, 14–20. Later

Requirements are recorded in `docs/TASKS.md`. They're revisited after items 1–5 and 13:

- 6: graceful SIGTERM shutdown (app code).
- 7: arm64 node affinity.
- 8: NetworkPolicy (Envoy-only ingress).
- 9: `imagePullSecrets` / GHCR visibility.
- 10: version injection and chart version.
- 11: resources, HPA, ServiceAccount.
- 12: `values-<env>.yaml`.
- 14: docs index and the `helm/`/`src/` vs `k8s/`/root `Dockerfile` note.
- 15: architecture and deployment docs.
- 16: scaling doc.
- 17: `SECURITY.md`.
- 18: `RELEASE.md`.
- 19: EKS doc.
- 20: global image distribution doc.

## 13. Cleanup workflow

**Requirement:** README L94 "Maintaining image versions and tags and removing old ones", L116 "How to manage older and stale versions of the application".

**Do:**
- New `.github/workflows/cleanup.yml`: `schedule` (weekly cron) plus `workflow_dispatch` with a `dry-run` input (default `true` for manual runs). `permissions: packages: write`.
- Prune `ghcr.io/yoyobesser/echo-pong` versions:
  - Untagged versions.
  - Per-commit `<sha>` tags older than N days (proposed: 14).
  - `<branch-slug>-cache` tags whose branch no longer exists.
- Never touch release tags `vX.Y.Z` or `main-cache`.
- Tool: `gh api` against the GitHub Packages REST API, from a script under `.github/scripts/`, so the policy stays readable and testable. Alternatives considered: `actions/delete-package-versions`, `dataaxiom/ghcr-cleanup-action`.
- Remove the `cleanup` placeholder job from `cd.yml`.
- Summary: a table of deleted (or would-delete) tags.

**Done when:** a dry run lists the expected candidates; a real run deletes them; the retention policy is documented (docs section linked from the workflow comment); `TASKS.md` L94/L116 bullets updated.
