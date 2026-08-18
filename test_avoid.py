#!/usr/bin/env python3
"""Check that a top-up stays off roads the target tier already played.
`python3 test_avoid.py`.

Burning a clip stops the same clip coming back. It says nothing about a
*different* clip on the same stretch of road, which is a fresh slug to the
database and a repeat to the player -- and the corpus has interstate legs the
van drove many times, so it is the shape the repeat actually takes. Nothing
downstream can see it either: the set looks well spread, because within itself
it is. So the constraint is pinned here.
"""

import tempfile
from pathlib import Path

from make_rounds import avoided_points, select

# 0.05 degrees of latitude is ~5.6 km, 0.01 is ~1.1 km -- the same scale
# test_select.py works at, against the default 5 km spacing.
PLAYED = [{"lat": 34.00, "lng": -118.00}]


def at(slug, lat, lng, state="CA"):
    return {"slug": slug, "lat": lat, "lng": lng, "state": state}


NEAR = at("near", 34.01, -118.00)  # ~1.1 km from PLAYED
FAR = at("far", 34.50, -118.00)  # ~55 km away
FARTHER = at("farther", 35.00, -118.00)

# The near round is the best-ranked and still loses: it sits inside the spacing
# of somewhere this tier has already dealt.
chosen, backfilled = select([NEAR, FAR, FARTHER], 2, 5.0, 0, PLAYED)
assert [r["slug"] for r in chosen] == ["far", "farther"], chosen
assert backfilled == 0, backfilled

# Avoided points cost no round slots -- they are never candidates themselves, so
# asking for every round still returns every round that fits.
chosen, _ = select([FAR, FARTHER], 2, 5.0, 0, PLAYED)
assert len(chosen) == 2, chosen

# With nothing to avoid the behaviour is exactly as before, so the flag is off
# by absence rather than by a separate code path.
chosen, _ = select([NEAR, FAR], 2, 5.0, 0, [])
assert [r["slug"] for r in chosen] == ["near", "far"], chosen
assert select([NEAR, FAR], 2, 5.0, 0) == select([NEAR, FAR], 2, 5.0, 0, [])

# A set that cannot be filled without crowding still fills, and says so -- the
# backfill drops the spacing for avoided points on the same terms as for the
# set's own rounds, because a short round set is worse than a crowded one.
chosen, backfilled = select([NEAR], 1, 5.0, 0, PLAYED)
assert [r["slug"] for r in chosen] == ["near"], chosen
assert backfilled == 1, backfilled

with tempfile.TemporaryDirectory() as tmp:
    f = Path(tmp) / "avoid.txt"

    f.write_text("# where prod already dealt\n34.0,-118.0\n\n 35.5 , -120.25 \n")
    assert avoided_points(f) == [
        {"lat": 34.0, "lng": -118.0},
        {"lat": 35.5, "lng": -120.25},
    ], avoided_points(f)

    # A file of only comments avoids nothing rather than everything.
    f.write_text("# nothing dealt yet\n\n")
    assert avoided_points(f) == [], avoided_points(f)

    # A line that isn't two numbers is a broken query, not a point to skip past.
    f.write_text("34.0,-118.0\nnot-a-point\n")
    try:
        avoided_points(f)
    except ValueError:
        pass
    else:
        raise AssertionError("a malformed avoid file must not pass silently")

print("ok: top-ups stay off already-played roads, and an empty file is a no-op")
