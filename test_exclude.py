#!/usr/bin/env python3
"""Check that a burned clip stays out of a set. `python3 test_exclude.py`.

The exclusion is what lets a top-up target a tier that already holds rounds:
without it a regeneration can hand players a clip they have seen, or -- worse --
write a schedule row pointing at a round somebody rejected, since the pool
insert is INSERT OR IGNORE and keeps the rejected row exactly as it is. Nothing
downstream re-checks this, so the filter is pinned here.
"""

import tempfile
from pathlib import Path

from make_rounds import burned_slugs, drop_burned

SCORED = [
    {"slug": "played", "median_km": 5, "mean_cos": 0.14},
    {"slug": "played", "median_km": 9, "mean_cos": 0.12},
    {"slug": "fresh", "median_km": 7, "mean_cos": 0.11},
    {"slug": "rejected", "median_km": 3, "mean_cos": 0.15},
]

with tempfile.TemporaryDirectory() as tmp:
    f = Path(tmp) / "burned.txt"

    # Every moment of a burned clip goes, not just the one that aired -- the
    # unit is the clip. Order and the surviving rows are untouched.
    f.write_text("# what production already holds\nplayed\n\nrejected\n")
    kept, dropped = drop_burned(SCORED, burned_slugs(f))
    assert [r["slug"] for r in kept] == ["fresh"], kept
    assert dropped == 3, dropped

    # Comments and blank lines are not slugs; a file of only those burns
    # nothing rather than everything.
    f.write_text("# nothing yet\n\n")
    assert burned_slugs(f) == set(), burned_slugs(f)
    kept, dropped = drop_burned(SCORED, burned_slugs(f))
    assert len(kept) == 4 and dropped == 0, (kept, dropped)

print("ok: burned clips stay out of the pool, whole-clip, comments ignored")
