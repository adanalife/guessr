#!/usr/bin/env python3
"""Fail when a name the docs cite does not resolve.

Two classes of reference, both of which have shipped broken before: a backticked
`task <name>` naming a task the Taskfile does not define — one such string was in
the 500 body of /api/day, so a player saw it — and a backticked repo-relative
path pointing at a file that is not in the repo.

Scans every tracked text file. Backticks are what make this cheap: a bare word
in prose is not a claim about the repo, so requiring the code-span keeps the
false-positive rate at zero without a grammar. CHANGELOG.md and changelog.d/ are
excluded because they are history — a path that was real when the entry was
written is not a defect now.

Anything legitimately absent goes in scripts/doc-names-allow.txt, one name per
line, with the reason beside it.
"""

import os
import re
import subprocess
import sys
from pathlib import Path

ROOT = Path(__file__).resolve().parent.parent
ALLOW = ROOT / "scripts" / "doc-names-allow.txt"

# The extensions a repo-relative path in these docs actually uses. Kept explicit
# so a version string like `1.2.3` or a hostname can never read as a path.
SUFFIXES = "py|sh|mjs|js|md|yml|yaml|toml|sql|html|css|json|jsonc|txt"
TASK_REF = re.compile(r"`task ([a-z][\w:-]*)`")
PATH_REF = re.compile(rf"`([\w][\w./-]*\.(?:{SUFFIXES}))`")
# Top-level keys under `tasks:` — two-space indent, nothing after the colon.
TASK_DEF = re.compile(r"^  ([a-z][\w:-]*):\s*$")

SKIP_DIRS = ("changelog.d/", "web/vendor/", "node_modules/")
SKIP_FILES = ("CHANGELOG.md",)
BINARY = {".jpg", ".jpeg", ".png", ".ico", ".webp", ".mp4", ".gz", ".woff2", ".pdf"}


def tracked() -> list[str]:
    out = subprocess.run(
        ["git", "ls-files"], cwd=ROOT, capture_output=True, text=True, check=True
    )
    return out.stdout.split()


def main() -> int:
    files = tracked()
    known_files = set(files)
    tasks = {
        m.group(1)
        for line in (ROOT / "Taskfile.yml").read_text().splitlines()
        if (m := TASK_DEF.match(line))
    }
    allowed = {
        line.split("#", 1)[0].strip()
        for line in ALLOW.read_text().splitlines()
        if line.split("#", 1)[0].strip()
    }

    findings: list[str] = []
    for rel in files:
        if rel in SKIP_FILES or rel.startswith(SKIP_DIRS):
            continue
        path = ROOT / rel
        if path.suffix.lower() in BINARY:
            continue
        try:
            text = path.read_text()
        except (UnicodeDecodeError, OSError):
            continue
        for n, line in enumerate(text.splitlines(), 1):
            for m in TASK_REF.finditer(line):
                name = m.group(1)
                if name not in tasks and name not in allowed:
                    findings.append(f"{rel}:{n}: no such task: `task {name}`")
            for m in PATH_REF.finditer(line):
                ref = m.group(1)
                if ref in allowed or ref in known_files:
                    continue
                # A bare filename resolves against any directory: the docs write
                # `check.py`, not `scripts/check.py`, and both are unambiguous
                # here because no two tracked files share a basename.
                if any(f.endswith("/" + ref) for f in known_files):
                    continue
                findings.append(f"{rel}:{n}: no such file: `{ref}`")

    # An `::error::` line is what puts the finding in the PR's checks tab rather
    # than only in the log; plain text everywhere else.
    prefix = "::error::" if os.environ.get("GITHUB_ACTIONS") else ""
    for f in findings:
        print(prefix + f)
    if findings:
        print(
            f"\n{len(findings)} unresolved reference(s). Fix the name, or add it to "
            f"{ALLOW.relative_to(ROOT)} with the reason.",
            file=sys.stderr,
        )
        return 1
    print(f"every cited task and path resolves ({len(files)} tracked files)")
    return 0


if __name__ == "__main__":
    raise SystemExit(main())
