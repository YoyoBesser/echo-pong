#!/usr/bin/env python3
"""Prune old GHCR image versions by retention policy; dry-run by default. See docs/CI.md#image-cleanup"""

import argparse
import json
import re
import subprocess
import sys
from datetime import UTC, datetime, timedelta

SHA_TAG = re.compile(r"^[0-9a-f]{40}$")
RELEASE_TAG = re.compile(r"^v\d+\.\d+\.\d+$")
CACHE_TAG = re.compile(r"^(.+)-cache$")


def slugify(branch):
    """Same rule as gather-metadata's branch-slug output."""
    slug = re.sub(r"[^a-z0-9._-]+", "-", branch.lower())
    return re.sub(r"-+$", "", re.sub(r"^[.-]+", "", slug))[:100]


def keep_reason(tags, created, live_slugs, cutoff):
    """Why a tagged version stays, or None if policy says delete."""
    for tag in tags:
        if RELEASE_TAG.match(tag):
            return "release"
        m = CACHE_TAG.match(tag)
        if m and m.group(1) in live_slugs:
            return "cache of live branch"
        if SHA_TAG.match(tag) and created >= cutoff:
            return "recent commit"
        if not (m or SHA_TAG.match(tag)):
            return "unknown tag (kept to be safe)"
    return None


def delete_reason(tags):
    if any(CACHE_TAG.match(t) for t in tags):
        return "cache of deleted branch"
    return "commit image past max age"


def plan(versions, live_slugs, children_of, now, max_age_days):
    """Split versions into (keep, delete) lists of (version, reason)."""
    cutoff = now - timedelta(days=max_age_days)
    keep, delete, protected = [], [], set()
    for v in versions:
        tags = v["tags"]
        if not tags:
            continue
        reason = keep_reason(tags, v["created"], live_slugs, cutoff)
        if reason:
            keep.append((v, reason))
            protected |= children_of(tags[0])
        else:
            delete.append((v, delete_reason(tags)))
    for v in versions:
        if not v["tags"]:
            if v["digest"] in protected:
                keep.append((v, "platform manifest of a kept index"))
            else:
                delete.append((v, "untagged"))
    return keep, delete


def gh(*args):
    out = subprocess.run(["gh", "api", *args], capture_output=True, text=True, check=True).stdout
    return json.loads(out) if out.strip() else None


def gh_pages(path):
    """All items across pages; gh --paginate --slurp yields a list of pages."""
    return [item for page in gh("--paginate", "--slurp", path) for item in page]


def image_children(image):
    def children_of(tag):
        raw = subprocess.run(
            ["docker", "buildx", "imagetools", "inspect", "--raw", f"{image}:{tag}"],
            capture_output=True,
            text=True,
            check=True,
        ).stdout
        return {m["digest"] for m in json.loads(raw).get("manifests", [])}

    return children_of


def render(keep, delete, dry_run):
    verb = "Would delete" if dry_run else "Deleted"
    lines = [f"### Image cleanup ({'dry run' if dry_run else 'live'})\n", f"{verb} {len(delete)}, kept {len(keep)}.\n"]
    lines += ["| Action | Tags | Digest | Created | Reason |", "|---|---|---|---|---|"]
    for action, rows in (("delete", delete), ("keep", keep)):
        for v, reason in rows:
            tags = ", ".join(f"`{t}`" for t in v["tags"]) or "—"
            lines.append(f"| {action} | {tags} | `{v['digest'][:19]}` | {v['created']:%Y-%m-%d} | {reason} |")
    return "\n".join(lines) + "\n"


def main(argv, now=None):
    p = argparse.ArgumentParser(description=__doc__)
    p.add_argument("--image", required=True, help="ghcr.io/<owner>/<package>")
    p.add_argument("--repo", required=True, help="<owner>/<repo>, for the live branch list")
    p.add_argument("--max-age-days", type=int, default=14)
    p.add_argument("--live", action="store_true", help="actually delete (default: dry run)")
    a = p.parse_args(argv[1:])

    owner, package = a.image.removeprefix("ghcr.io/").split("/", 1)
    kind = "orgs" if gh(f"/users/{owner}")["type"] == "Organization" else "users"
    base = f"/{kind}/{owner}/packages/container/{package}/versions"
    versions = [
        {
            "id": v["id"],
            "digest": v["name"],
            "tags": v["metadata"]["container"]["tags"],
            "created": datetime.fromisoformat(v["created_at"]),
        }
        for v in gh_pages(f"{base}?per_page=100")
    ]
    live_slugs = {slugify(b["name"]) for b in gh_pages(f"/repos/{a.repo}/branches?per_page=100")}

    keep, delete = plan(versions, live_slugs, image_children(a.image), now or datetime.now(UTC), a.max_age_days)
    if a.live:
        for v, _ in delete:
            gh("--method", "DELETE", f"{base}/{v['id']}")
    sys.stdout.write(render(keep, delete, not a.live))
    return 0


if __name__ == "__main__":  # pragma: no cover
    sys.exit(main(sys.argv))
