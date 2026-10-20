import json

import pytest
import render


def row(kind="tests", check="c", scope="all", job="j", outcome="success", conclusion="success"):
    return {"kind": kind, "check": check, "scope": scope, "job": job, "outcome": outcome, "conclusion": conclusion}


@pytest.mark.parametrize(
    ("outcome", "conclusion", "want"),
    [
        ("success", "success", "✅ pass"),
        ("failure", "success", "⚠️ fail (non-blocking)"),
        ("failure", "failure", "❌ fail"),
        ("cancelled", "cancelled", "🚫 cancelled"),
        ("skipped", "skipped", "⏭️ skipped"),
        ("", "", "⏭️ skipped"),
    ],
)
def test_cell(outcome, conclusion, want):
    assert render.cell(row(outcome=outcome, conclusion=conclusion)) == want


def test_render_empty():
    assert render.render([], ["lint"]) == (
        "### Tests\n\n_No checks recorded._\n\n### Security\n\n_No checks recorded._\n\n"
    )


def test_render_pivots_scopes_and_orders_jobs():
    rows = [
        row(check="CLI e2e", scope="arm64", job="e2e"),
        row(check="CLI e2e", scope="amd64", job="e2e", outcome="failure", conclusion="failure"),
        row(check="go vet", job="lint", outcome="failure"),
        row(kind="security", check="trivy", scope="arm64", job="build"),
        row(kind="security", check="unordered", scope="arm64", job="other"),
    ]
    out = render.render(rows, ["lint", "build", "e2e"])
    assert out == (
        "### Tests\n\n"
        "| Check | all | amd64 | arm64 |\n"
        "|---|---|---|---|\n"
        "| go vet | ⚠️ fail (non-blocking) | — | — |\n"
        "| CLI e2e | — | ❌ fail | ✅ pass |\n"
        "\n"
        "### Security\n\n"
        "| Check | all | amd64 | arm64 |\n"
        "|---|---|---|---|\n"
        "| trivy | — | — | ✅ pass |\n"
        "| unordered | — | — | ✅ pass |\n"
        "\n"
    )


def test_load_and_main(tmp_path, capsys):
    (tmp_path / "b.jsonl").write_text(json.dumps(row(check="b")) + "\n\n")
    (tmp_path / "a.jsonl").write_text(json.dumps(row(check="a")) + "\n")
    (tmp_path / "ignored.txt").write_text("not json")
    assert [r["check"] for r in render.load(tmp_path)] == ["a", "b"]

    render.main(["render.py", str(tmp_path), "j"])
    assert "| a | ✅ pass |" in capsys.readouterr().out
