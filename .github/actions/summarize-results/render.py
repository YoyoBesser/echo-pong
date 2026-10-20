#!/usr/bin/env python3
"""Render ci-results/*.jsonl as Tests and Security tables (checks x scopes). See .github/workflows/AGENTS.md"""

import glob
import json
import sys

KINDS = (("tests", "Tests"), ("security", "Security"))


def load(results_dir):
    rows = []
    for path in sorted(glob.glob(f"{results_dir}/*.jsonl")):
        with open(path) as f:
            rows += [json.loads(line) for line in f if line.strip()]
    return rows


def cell(row):
    outcome = row["outcome"]
    if outcome == "success":
        return "✅ pass"
    if outcome == "failure":
        return "⚠️ fail (non-blocking)" if row["conclusion"] == "success" else "❌ fail"
    if outcome == "cancelled":
        return "🚫 cancelled"
    return "⏭️ skipped"


def render(rows, order):
    rank = {job: i for i, job in enumerate(order)}
    rows = sorted(rows, key=lambda r: rank.get(r["job"], len(order)))
    scopes = sorted({r["scope"] for r in rows}, key=lambda s: (s != "all", s))
    out = []
    for kind, title in KINDS:
        kind_rows = [r for r in rows if r["kind"] == kind]
        out.append(f"### {title}\n")
        if not kind_rows:
            out.append("_No checks recorded._\n")
            continue
        out.append("| Check | " + " | ".join(scopes) + " |")
        out.append("|---|" + "|".join("---" for _ in scopes) + "|")
        for check in dict.fromkeys(r["check"] for r in kind_rows):
            cells = [next((cell(r) for r in kind_rows if r["check"] == check and r["scope"] == s), "—") for s in scopes]
            out.append(f"| {check} | " + " | ".join(cells) + " |")
        out.append("")
    return "\n".join(out) + "\n"


def main(argv):
    results_dir, order = argv[1], argv[2:]
    sys.stdout.write(render(load(results_dir), order))


if __name__ == "__main__":  # pragma: no cover
    main(sys.argv)
