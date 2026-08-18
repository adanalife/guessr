#!/usr/bin/env python3
"""Check that the three files naming a clip still agree. `python3 test_clip_name.py`.

One rule -- `<slug>-<milliseconds>.mp4` -- is implemented three times, in two
languages, by three programs that never call each other:

  - make_rounds.clip_name writes the name.
  - functions/clips/[[path]].js decides from the name whether the footage may be
    cached for a year as `immutable`.
  - rebuild.parse_image reads the name back to find the moment to re-cut.

Nothing ties them together, and the ways they can drift apart are quiet ones.
Narrow the padding in clip_name and every clip silently drops from a year's
cache to an hour -- no error, no failed test, just clips billed against the
Functions request budget at roughly 8,000x the rate the year-long cache was
bought to avoid. Widen the regex and a bare `<slug>.mp4` takes the immutable
header, which is the failure the header was reasoned about to prevent: a
regeneration putting different footage behind a URL somebody already holds.

So the worker's regex is read out of its own source rather than copied here.
A fourth copy of the rule would drift the same way the first three can.
"""

import re
from pathlib import Path

from make_rounds import clip_name
from rebuild import parse_image

WORKER = Path(__file__).parent / "functions" / "clips" / "[[path]].js"

found = re.search(r"^const MOMENT_IN_NAME = /(.+)/;$", WORKER.read_text(), re.M)
# Without this the whole file passes by testing an empty pattern against nothing.
assert found, f"no MOMENT_IN_NAME regex in {WORKER} -- this test has lost its subject"
moment_in_name = re.compile(found.group(1))

# The shapes a slug really takes, plus the ones that would break a naive split:
# a slug already ending in -<digits>, one ending in a bare hyphen, one that is
# only digits. The legacy `_opt` spelling is what production's ten pre-guessr#81
# rounds carry.
SLUGS = [
    "2018_0704_123456_001",
    "2018_0910_133333_013_opt",
    "a-b-c",
    "foo-123",
    "x-9",
    "slug-",
    "12345",
    "s-0",
]
# 0 is a clip cut at its very first frame; 999.9996 rounds up across a second.
MOMENTS = [0, 0.5, 1.2345, 3.0, 123.456, 999.9994, 999.9996, 3600.0]


def test_every_generated_name_earns_the_immutable_year():
    for slug in SLUGS:
        for ts in MOMENTS:
            name = clip_name({"slug": slug, "ts": ts})
            assert moment_in_name.search(name), (
                f"{name!r} does not match the worker's {found.group(1)!r}, so this "
                f"clip would be served with a one-hour cache instead of a year"
            )


def test_a_name_round_trips_back_to_the_moment_it_was_cut_from():
    # rebuild re-cuts from this, so a name that parses to the wrong millisecond
    # replaces a round's footage with a different three seconds of road.
    for slug in SLUGS:
        for ts in MOMENTS:
            name = clip_name({"slug": slug, "ts": ts})
            assert parse_image(f"clips/{name}") == (slug, round(ts * 1000)), (
                f"{name!r} parsed back to {parse_image(f'clips/{name}')!r}"
            )


def test_a_name_without_a_moment_is_refused_the_immutable_year():
    # The other half of the rule, and the one with teeth: these are the pre-#81
    # names production still schedules, and their footage IS reproducible
    # differently, so caching one for a year is unrecoverable.
    for slug in SLUGS:
        legacy = f"{slug}.mp4"
        assert not moment_in_name.search(legacy), (
            f"{legacy!r} matches the immutable rule, but a regeneration can put "
            f"different footage behind it"
        )
        assert parse_image(f"clips/{legacy}")[1] is None, (
            f"{legacy!r} was read as carrying a moment it does not have"
        )


test_every_generated_name_earns_the_immutable_year()
test_a_name_round_trips_back_to_the_moment_it_was_cut_from()
test_a_name_without_a_moment_is_refused_the_immutable_year()
print("ok: clip_name, the worker's cache rule, and parse_image agree on one name")
