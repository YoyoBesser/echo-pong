# AGENTS.md

Conventions for anyone (human or agent) editing this repo.

## Comments

Applies to all code and config: Go, YAML (workflows, actions, Helm), Dockerfile, shell.

- Max 1-2 lines per comment. No comment blocks, no essays.
- Say *what* or flag a gotcha; put the *why* in docs and link it:
  ```yaml
  # Untrusted input via env, never inline. See docs/CI.md#script-injection
  ```
- Link format: repo-relative path + heading anchor, e.g. `docs/RELEASE.md#tag-format`.
- Linked anchor must exist. Adding a link means adding the doc section in the same change. CI checks this ([docs/CI.md#doc-links](docs/CI.md#doc-links)).
- No comment restating the code. If nothing non-obvious, no comment.

Doc-writing rules: [docs/AGENTS.md](docs/AGENTS.md).

## Changelog

Every PR that changes app behaviour, tooling, workflows, guardrails or delivery config (image, chart) appends an entry at the top of [docs/CHANGELOG.md](docs/CHANGELOG.md), in the same PR. Follow the format and the **Action needed** values defined there.

## Layout

- `src/`: Go service (`Dockerfile`, e2e tests in `src/test/e2e/`).
- `helm/echo-pong/`: Helm chart (Envoy Gateway subchart, Gateway API routing).
- `docs/TASKS.md`: README requirements by line number, with how we meet each (done/planned).
- `docs/plans/`: in-depth implementation plans. Written only when the user asks for a specific one.
- `docs/*.md`: reference docs, the targets of code-comment links.
- `docs/CHANGELOG.md`: one entry per PR, newest first.
