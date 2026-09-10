#!/usr/bin/env python3
"""Pin scripts/check-doc-names.py — the two patterns, and the allowlist.

The gate's failure mode is silence: a regex that stops matching, or an allowlist
entry that quietly swallows a real reference, both leave the step green forever.
"""

import importlib.util
import subprocess
from pathlib import Path

ROOT = Path(__file__).parent
spec = importlib.util.spec_from_file_location(
    "check_doc_names", ROOT / "scripts" / "check-doc-names.py"
)
check = importlib.util.module_from_spec(spec)
spec.loader.exec_module(check)


def test_task_pattern_needs_the_backticks():
    assert check.TASK_REF.findall("run `task schema:stage:push` first") == [
        "schema:stage:push"
    ]
    # Prose is not a claim about the repo, so a bare mention must not match.
    assert check.TASK_REF.findall("this task above is a chore") == []


def test_path_pattern_matches_paths_and_nothing_else():
    assert check.PATH_REF.findall("see `web/admin/notes.html` and `check.py`") == [
        "web/admin/notes.html",
        "check.py",
    ]
    assert check.PATH_REF.findall("pinned at `1.20.3` on `guessr.dana.lol`") == []


def test_the_taskfile_parse_finds_real_tasks():
    tasks = {
        m.group(1)
        for line in (ROOT / "Taskfile.yml").read_text().splitlines()
        if (m := check.TASK_DEF.match(line))
    }
    listed = subprocess.run(
        ["grep", "-c", "^  [a-z]", str(ROOT / "Taskfile.yml")],
        capture_output=True,
        text=True,
    )
    assert tasks, "no tasks parsed out of the Taskfile — the indent rule drifted"
    assert len(tasks) <= int(listed.stdout), "parsed more tasks than candidate lines"


def test_every_allowlist_entry_is_still_absent():
    """An allowlisted name that becomes a real file should leave the allowlist.

    Otherwise the entry goes on suppressing whatever else cites that name.
    """
    tracked = set(
        subprocess.run(
            ["git", "ls-files"],
            cwd=ROOT,
            capture_output=True,
            text=True,
            check=True,
        ).stdout.split()
    )
    for line in (ROOT / "scripts" / "doc-names-allow.txt").read_text().splitlines():
        entry = line.split("#", 1)[0].strip()
        if not entry:
            continue
        assert entry not in tracked, f"{entry} exists now — drop it from the allowlist"


def test_the_repo_itself_passes():
    assert check.main() == 0


if __name__ == "__main__":
    for name, fn in sorted(globals().items()):
        if name.startswith("test_"):
            fn()
            print(f"ok {name}")
