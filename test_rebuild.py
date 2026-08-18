#!/usr/bin/env python3
"""Check that a rebuild refuses to put the wrong footage at a cached key.
`python3 test_rebuild.py`.

`functions/clips/[[path]].js` serves clips `immutable` for a year, so the one
thing a rebuild must never do is land different bytes at a name a player already
holds. Nothing downstream can notice if it does: the object is a valid mp4 of a
real road, the endpoint returns 200, and the only symptom is a round whose answer
no longer matches its footage. So every reason to refuse is pinned here.

The cut itself is `make_rounds.extract_clip`, which test_check.py already stands
behind. What is new in a rebuild is deciding *whether* to cut.
"""

import tempfile
from pathlib import Path

import rebuild
from rebuild import check, parse_image

# The moment lives in the key, and a slug may hold hyphens of its own -- so the
# split has to come off the last one, not the first.
assert parse_image("clips/2018_0704_123456_001-012345.mp4") == (
    "2018_0704_123456_001",
    12345,
)
assert parse_image("clips/a-b-c-000500.mp4") == ("a-b-c", 500)
# With or without the surrounding key parts, since a caller may paste either.
assert parse_image("2018_0704_123456_001-012345.mp4") == (
    "2018_0704_123456_001",
    12345,
)

# Keys with no moment in them are the pre-guessr#81 naming, and production still
# schedules ten. They parse to a moment of None rather than raising -- the oldest
# rounds are the likeliest to have lost their media, so putting them out of reach
# of the restore tool would be exactly backwards.
assert parse_image("clips/2018_0910_133333_013_opt.mp4") == (
    "2018_0910_133333_013_opt",
    None,
)
assert parse_image("clips/slug-12x45.mp4") == ("slug-12x45", None)


# The corpus is not mounted in CI, so point CORPUS at a directory this test owns
# and touch the one clip the rows below claim to come from. Every check but the
# missing-corpus one is about the row and the key disagreeing, which needs no
# media at all.
tmp = tempfile.TemporaryDirectory()
rebuild.CORPUS = Path(tmp.name)
(rebuild.CORPUS / "roadclip.MP4").touch()

OK_ROW = {
    "slug": "roadclip",
    "source_ts_sec": 42.5,
    "clip_ts_sec": 42.5,
    "status": "scheduled",
}

assert check("clips/roadclip-042500.mp4", OK_ROW, 42500, "roadclip") == []

# A key whose slug is not the round's slug: cutting either one puts a road at a
# URL that promised the other.
wrong_slug = check("clips/other-042500.mp4", OK_ROW, 42500, "other")
assert len(wrong_slug) == 2, wrong_slug  # the mismatch, and no other.MP4 to cut
assert any("slug" in p for p in wrong_slug), wrong_slug

# A key whose millisecond is not the round's. The key is what the cache promises,
# so this is unresolvable rather than a rounding nit.
off_by_a_second = check("clips/roadclip-043500.mp4", OK_ROW, 43500, "roadclip")
assert len(off_by_a_second) == 1, off_by_a_second
assert "43.5s" in off_by_a_second[0], off_by_a_second

# Milliseconds are integers on the way in and floats in the row, so the
# comparison has to round rather than compare exactly.
assert (
    check(
        "clips/roadclip-042501.mp4",
        {**OK_ROW, "source_ts_sec": 42.5006, "clip_ts_sec": 42.5006},
        42501,
        "roadclip",
    )
    == []
)

# A corpus clip that is not mounted. Distinct from a missing round: there is
# something to rebuild, just nothing to rebuild it from.
missing = check(
    "clips/absent-000100.mp4",
    {**OK_ROW, "slug": "absent", "source_ts_sec": 0.1, "clip_ts_sec": 0.1},
    100,
    "absent",
)
assert len(missing) == 1, missing
assert "GUESSR_CORPUS" in missing[0], missing

# The 3% whose corpus cut was trimmed: their offset is relative to that cut, so a
# trim moved since generation makes this millisecond name different footage --
# and nothing records the trim to check against. Refused unless forced.
trimmed = check(
    "clips/roadclip-042500.mp4",
    {**OK_ROW, "source_ts_sec": 51.0},
    42500,
    "roadclip",
)
assert len(trimmed) == 1, trimmed
assert "trim-relative" in trimmed[0], trimmed

# All ten of production's legacy rounds: no moment in the key, and provenance
# backfilled to zero when the pool adopted them. Cutting at 0s would put the start
# of the source clip at a URL answering a different stretch of road, so there is
# nothing to rebuild from and nothing --force can fix.
unrecoverable = check(
    "clips/2018_0910_133333_013_opt.mp4",
    {
        "slug": "roadclip",
        "source_ts_sec": 0,
        "clip_ts_sec": 0,
        "status": "scheduled",
    },
    None,
    "roadclip",
)
assert len(unrecoverable) == 1, unrecoverable
assert "records no moment" in unrecoverable[0], unrecoverable

# A legacy key whose row *does* carry a moment: the row is uncorroborated rather
# than absent, which is a risk to accept rather than a dead end.
uncorroborated = check(
    "clips/roadclip.mp4", OK_ROW | {"clip_ts_sec": 42.5}, None, "roadclip"
)
assert len(uncorroborated) == 1, uncorroborated
assert "cannot be corroborated" in uncorroborated[0], uncorroborated

print("ok: rebuild refuses every disagreement between a key and its round")
