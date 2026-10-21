# docs/AGENTS.md

Rules for writing docs in `docs/`. Repo-wide rules: [../AGENTS.md](../AGENTS.md).

## Contents

- [Reference docs are link targets](#reference-docs-are-link-targets)
- [Contents section](#contents-section)
- [Other docs](#other-docs)

## Reference docs are link targets

Code comments stay short and point here (`docs/CI.md#script-injection`), so the depth lives in these files.

- One file per area, upper-case: `CI.md`, `RELEASE.md`, `CD.md`, `CONTAINER.md`, `HELM.md`, `SECURITY.md`, ...
- One `##`/`###` heading per linkable topic. The anchor is GitHub's slug: lowercase, spaces become `-`, punctuation dropped (`## Script injection` → `#script-injection`).
- Headings are an API. Before renaming or deleting one, find inbound links (`grep -rn 'docs/CI.md#script-injection' .`) and update them in the same change.
- Each section opens with the decision or rule in 1-2 sentences, then the reasoning, then alternatives considered if relevant.
- Link back to the code it explains (`.github/actions/gather-metadata/action.yml`) so readers can jump both ways.

## Contents section

Every doc in `docs/` (except `CLAUDE.md`) has a `## Contents` list before its first section. It links each `##` heading, with `###` headings nested under their parent. Update it in the same change that adds, renames or removes a heading. In `CHANGELOG.md` it covers the format sections only, not the entries.

## Other docs

- `CHANGELOG.md`: append-only, newest first, one entry per PR. Use the entry template in the file. **Intent** and **Result** are one sentence each, in caveman `/lite` style. Fill every structured field (`none` is fine). Never edit past entries, except to fix the PR link or date on merge.
- `TASKS.md`: README requirements quoted verbatim with line links (`[L49](../README.md?plain=1#L49)`), grouped by README section. Under each, terse `[x]`/`[ ]` bullets for how we meet it, linking reference docs. Tick a bullet in the same PR that delivers it.
- `plans/`: one file per plan, created only on request. Plans are working docs. Code comments link to reference docs, never to plans.
