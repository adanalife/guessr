#!/usr/bin/env python3
"""available() names what it drops. `python3 test_available.py`.

A scored row whose clip isn't in the corpus directory used to vanish, so a
pool could shrink -- a trip parked in another directory, a row the mount lacks
-- with the run reporting a smaller set and no reason. Now the missing slugs
come back beside the kept rows.
"""

import tempfile
from pathlib import Path

import make_rounds

with tempfile.TemporaryDirectory() as d:
    (Path(d) / "2018_0514_224801_001_opt.MP4").touch()
    make_rounds.CORPUS = Path(d)
    scored = [
        {"slug": "2018_0514_224801_001_opt", "ts": 1.0},
        {"slug": "2018_0514_224801_001_opt", "ts": 7.0},  # a second moment, same clip
        {"slug": "20260605144519_000001_s0180", "ts": 3.0},  # parked elsewhere
        {"slug": "20260605144519_000001_s0180", "ts": 9.0},
    ]
    kept, missing = make_rounds.available(scored)
    assert [r["ts"] for r in kept] == [1.0, 7.0], kept
    assert missing == ["20260605144519_000001_s0180"], (
        missing
    )  # once per clip, not per moment

    kept, missing = make_rounds.available(scored[:2])
    assert len(kept) == 2 and missing == []

print("ok")
