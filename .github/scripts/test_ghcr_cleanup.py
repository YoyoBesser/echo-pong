import json
from datetime import UTC, datetime, timedelta

import ghcr_cleanup as gc
import pytest

NOW = datetime(2026, 10, 21, tzinfo=UTC)
OLD = NOW - timedelta(days=30)
NEW = NOW - timedelta(days=1)
SHA_OLD = "a" * 40
SHA_NEW = "b" * 40


def v(id_, tags, created=NEW, digest=None):
    return {"id": id_, "digest": digest or f"sha256:{id_:064d}", "tags": tags, "created": created}


@pytest.mark.parametrize(
    ("branch", "slug"),
    [
        ("feat/yonatan.besser/home-assignment-init", "feat-yonatan.besser-home-assignment-init"),
        ("main", "main"),
        ("Feature/Foo__Bar//baz-", "feature-foo__bar-baz"),
        ("..x", "x"),
    ],
)
def test_slugify_matches_gather_metadata(branch, slug):
    assert gc.slugify(branch) == slug


def test_plan_applies_policy_and_protects_index_children():
    versions = [
        v(1, ["v1.2.3"], OLD),
        v(2, [SHA_OLD], OLD),
        v(3, [SHA_NEW], NEW),
        v(4, ["main-cache"], OLD),
        v(5, ["gone-branch-cache"], OLD),
        v(6, ["latest"], OLD),
        v(7, [], digest="sha256:child-of-new"),
        v(8, [], digest="sha256:orphan"),
    ]
    children = {"v1.2.3": set(), SHA_NEW: {"sha256:child-of-new"}, "main-cache": set(), "latest": set()}
    keep, delete = gc.plan(versions, {"main"}, children.__getitem__, NOW, 14)
    assert [(k["id"], r) for k, r in keep] == [
        (1, "release"),
        (3, "recent commit"),
        (4, "cache of live branch"),
        (6, "unknown tag (kept to be safe)"),
        (7, "platform manifest of a kept index"),
    ]
    assert [(d["id"], r) for d, r in delete] == [
        (2, "commit image past max age"),
        (5, "cache of deleted branch"),
        (8, "untagged"),
    ]


def test_render_dry_run_and_live():
    keep = [(v(1, ["v1.2.3"]), "release")]
    delete = [(v(2, []), "untagged")]
    dry = gc.render(keep, delete, dry_run=True)
    assert "### Image cleanup (dry run)" in dry
    assert "Would delete 1, kept 1." in dry
    assert "| delete | — | `sha256:000000000000` | 2026-10-20 | untagged |" in dry
    assert "| keep | `v1.2.3` |" in dry
    assert "Deleted 0, kept 0." in gc.render([], [], dry_run=False)


class FakeRun:
    """Stands in for subprocess.run for gh and docker calls."""

    def __init__(self, responses):
        self.responses, self.calls = responses, []

    def __call__(self, cmd, **_):
        self.calls.append(cmd)
        key = " ".join(cmd)
        out = next((r for k, r in self.responses.items() if k in key), "")
        return type("R", (), {"stdout": out if isinstance(out, str) else json.dumps(out)})()


def api_version(id_, tags, created, digest):
    return {"id": id_, "name": digest, "created_at": created.isoformat(), "metadata": {"container": {"tags": tags}}}


@pytest.mark.parametrize(("owner_type", "kind"), [("User", "users"), ("Organization", "orgs")])
@pytest.mark.parametrize("live", [False, True])
def test_main_end_to_end(monkeypatch, capsys, owner_type, kind, live):
    fake = FakeRun(
        {
            "api /users/yoyobesser": {"type": owner_type},
            "--slurp /repos/o/r/branches": [[{"name": "main"}]],
            "--slurp /": [
                [api_version(1, [SHA_OLD], OLD, "sha256:old"), api_version(2, ["main-cache"], OLD, "sha256:mc")]
            ],
            "imagetools inspect --raw ghcr.io/yoyobesser/echo-pong:main-cache": {"mediaType": "x"},
            "--method DELETE": "",
        }
    )
    monkeypatch.setattr(gc.subprocess, "run", fake)
    argv = ["x", "--image", "ghcr.io/yoyobesser/echo-pong", "--repo", "o/r"] + (["--live"] if live else [])
    assert gc.main(argv, now=NOW) == 0
    out = capsys.readouterr().out
    deletes = [c for c in fake.calls if "DELETE" in c]
    assert deletes == (
        [["gh", "api", "--method", "DELETE", f"/{kind}/yoyobesser/packages/container/echo-pong/versions/1"]]
        if live
        else []
    )
    assert ("Deleted 1, kept 1." if live else "Would delete 1, kept 1.") in out


def test_main_defaults_now(monkeypatch, capsys):
    fake = FakeRun({"api /users/": {"type": "User"}, "--slurp": [[]]})
    monkeypatch.setattr(gc.subprocess, "run", fake)
    assert gc.main(["x", "--image", "ghcr.io/o/p", "--repo", "o/r"]) == 0
    assert "Would delete 0, kept 0." in capsys.readouterr().out
