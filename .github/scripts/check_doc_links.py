#!/usr/bin/env python3
"""Doc links must hit an existing heading; code links must be repo-root relative. See docs/CI.md#doc-links"""

import re
import subprocess
import sys
from pathlib import Path

HEADING = re.compile(r"^(#{1,6})\s+(.+?)\s*#*\s*$")
FENCE = re.compile(r"^\s*(```|~~~)")
MD_LINK = re.compile(r"\]\(([^)\s]+)\)")
CODE_LINK = re.compile(r"(?<![\w./-])((?:\.{1,2}/)?[\w./-]+\.md)#([\w-]+)")
LINE_ANCHOR = re.compile(r"L(\d+)")
INLINE_CODE = re.compile(r"`[^`]*`")


def slug(text):
    """GitHub heading anchor: lowercase, drop punctuation except - and _, spaces to -."""
    text = re.sub(r"[`*]", "", text.strip().lower())
    return re.sub(r"[^\w\- ]", "", text).replace(" ", "-")


def anchors(path):
    seen, out, fenced = {}, set(), False
    for line in path.read_text().splitlines():
        if FENCE.match(line):
            fenced = not fenced
            continue
        m = None if fenced else HEADING.match(line)
        if m:
            base = slug(m.group(2))
            n = seen.get(base, 0)
            seen[base] = n + 1
            out.add(base if n == 0 else f"{base}-{n}")
    return out


def check_target(root, target, anchor, where, errors, cache):
    if not target.is_file():
        errors.append(f"{where}: {target.relative_to(root)} does not exist")
        return
    m = LINE_ANCHOR.fullmatch(anchor)
    if m:
        if int(m.group(1)) > len(target.read_text().splitlines()):
            errors.append(f"{where}: {target.relative_to(root)} has no line {m.group(1)}")
        return
    if target not in cache:
        cache[target] = anchors(target)
    if anchor not in cache[target]:
        errors.append(f"{where}: no heading #{anchor} in {target.relative_to(root)}")


def check_file(root, rel, errors, cache):
    path = root / rel
    try:
        text = path.read_text()
    except UnicodeDecodeError, FileNotFoundError:
        return
    for lineno, line in enumerate(text.splitlines(), 1):
        where = f"{rel}:{lineno}"
        if rel.endswith(".md"):
            # Links inside `inline code` are text, not links.
            for link in MD_LINK.findall(INLINE_CODE.sub("", line)):
                if "#" not in link or re.match(r"\w+:", link):
                    continue
                ref, anchor = link.split("#", 1)
                ref = ref.split("?", 1)[0]
                target = (path.parent / ref).resolve() if ref else path
                check_target(root, target, anchor, where, errors, cache)
        else:
            for ref, anchor in CODE_LINK.findall(line):
                if ref.startswith(("./", "../")):
                    errors.append(f"{where}: {ref}#{anchor} must be relative to repo root")
                    continue
                check_target(root, root / ref, anchor, where, errors, cache)


def check(root, files):
    errors, cache = [], {}
    for rel in files:
        # Test files hold deliberately broken links as fixtures.
        if Path(rel).name.startswith("test_") and rel.endswith(".py"):
            continue
        check_file(root, rel, errors, cache)
    return errors


def main(argv):
    root = Path(argv[1] if len(argv) > 1 else ".").resolve()
    files = subprocess.run(["git", "ls-files"], cwd=root, capture_output=True, text=True, check=True).stdout.split()
    errors = check(root, files)
    for e in errors:
        print(f"::error::{e}")
    print(f"{len(files)} files checked, {len(errors)} broken doc links")
    return 1 if errors else 0


if __name__ == "__main__":  # pragma: no cover
    sys.exit(main(sys.argv))
