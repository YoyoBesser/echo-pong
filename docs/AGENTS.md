# docs/AGENTS.md

Rules for writing docs in `docs/`. Repo-wide rules: [../AGENTS.md](../AGENTS.md).

## Reference docs are link targets

Code comments stay short and point here (`docs/CI.md#script-injection`), so the depth lives in these files.

- One file per area, upper-case: `CI.md`, `RELEASE.md`, `CD.md`, `CONTAINER.md`, `HELM.md`, `SECURITY.md`, ...
- One `##`/`###` heading per linkable topic. The anchor is GitHub's slug: lowercase, spaces become `-`, punctuation dropped (`## Script injection` → `#script-injection`).
- Headings are an API. Before renaming or deleting one, find inbound links (`grep -rn 'docs/CI.md#script-injection' .`) and update them in the same change.
- Each section opens with the decision or rule in 1-2 sentences, then the reasoning, then alternatives considered if relevant.
- Link back to the code it explains (`.github/actions/gather-metadata/action.yml`) so readers can jump both ways.

## Other docs

- `tasks.md`: super terse bullets, grouped by section. No implementation detail.
- `plans/`: one file per plan, created only on request. Plans are working docs. Code comments link to reference docs, never to plans.
