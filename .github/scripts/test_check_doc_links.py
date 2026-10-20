import subprocess

import check_doc_links as cdl
import pytest


@pytest.mark.parametrize(
    ("heading", "want"),
    [
        ("Script injection", "script-injection"),
        ("`helm/echo-pong` values", "helmecho-pong-values"),
        ("SAST and SCA", "sast-and-sca"),
        ("**Bold** _x_", "bold-_x_"),
    ],
)
def test_slug(heading, want):
    assert cdl.slug(heading) == want


def test_anchors_skips_fences_and_numbers_duplicates(tmp_path):
    md = tmp_path / "a.md"
    md.write_text("# Top\n```\n# not a heading\n```\n## Dup\n## Dup ##\nplain\n")
    assert cdl.anchors(md) == {"top", "dup", "dup-1"}


def write(root, files):
    for rel, text in files.items():
        p = root / rel
        p.parent.mkdir(parents=True, exist_ok=True)
        p.write_text(text)
    return list(files)


def test_check_reports_every_kind_of_break(tmp_path):
    files = write(
        tmp_path,
        {
            "docs/CI.md": (
                "# CI\n## Good\nsee [x](#good) [y](#nope) [z](OTHER.md#good) [w](https://e.com#a) [v](CI.md)\n"
                "`[code](path#not-a-link)`\n"
            ),
            "docs/OTHER.md": "## Good\n[r](../README.md?plain=1#L2) [r](../README.md?plain=1#L9)\n",
            "README.md": "line1\nline2\n",
            "a.yml": (
                "# See docs/CI.md#good and docs/CI.md#missing\n"
                "# ../docs/CI.md#good ./docs/CI.md#good\n"
                "# docs/GONE.md#x\n"
            ),
            "blob.bin": "",
        },
    )
    (tmp_path / "blob.bin").write_bytes(b"\xff\xfe\x00")
    assert cdl.check(tmp_path, [*files, "deleted.txt"]) == [
        "docs/CI.md:3: no heading #nope in docs/CI.md",
        "docs/OTHER.md:2: README.md has no line 9",
        "a.yml:1: no heading #missing in docs/CI.md",
        "a.yml:2: ../docs/CI.md#good must be relative to repo root",
        "a.yml:2: ./docs/CI.md#good must be relative to repo root",
        "a.yml:3: docs/GONE.md does not exist",
    ]


def git_repo(root, files):
    write(root, files)
    subprocess.run(["git", "init", "-q"], cwd=root, check=True)
    subprocess.run(["git", "add", "-A"], cwd=root, check=True)


def test_main_ok(tmp_path, capsys):
    git_repo(tmp_path, {"docs/X.md": "## A\n", "x.sh": "# docs/X.md#a\n", "t/test_x.py": "# docs/NO.md#a\n"})
    assert cdl.main(["check", str(tmp_path)]) == 0
    assert "3 files checked, 0 broken doc links" in capsys.readouterr().out


def test_main_broken(tmp_path, capsys, monkeypatch):
    git_repo(tmp_path, {"x.sh": "# docs/X.md#a\n"})
    monkeypatch.chdir(tmp_path)
    assert cdl.main(["check"]) == 1
    assert "::error::x.sh:1: docs/X.md does not exist" in capsys.readouterr().out
