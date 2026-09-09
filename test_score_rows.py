#!/usr/bin/env python3
"""Check the scored pool psql hands back is read correctly. `python3 test_score_rows.py`.

parse_scored is where a round's shape is decided, and everything downstream of
it -- available(), rank(), select(), schedule() -- is already tested against
that shape. The gap this closes is that the shape itself was never pinned, and
the two ways it breaks are both silent:

  * A column added, dropped or reordered in SCORE_SQL's outer SELECT. An
    unexpected width is skipped as a psql acknowledgement line, so a changed
    query yields an empty pool rather than an error -- the generator produces
    nothing and says nothing.
  * A quality filter that stops filtering. Too-few-neighbours and too-wide-a
    -circle are what keep an unanswerable round out of the game; a round that
    slips past them plays fine and looks like every other one.
"""

import re

from make_rounds import SCORE_COLUMNS, SCORE_SQL, parse_scored

# One well-formed row, in SCORE_SQL's column order, with values far enough from
# every threshold that each case below fails for the reason it is testing.
FIELDS = [
    "gs-classic",  # slug
    "12.5",  # ts (offset into the clip)
    "812.5",  # source_ts (offset into the original recording)
    "41.8781",  # lat
    "-87.6298",  # lng
    "40",  # travel_m
    "Illinois",  # state
    "2019-06-01T00:00:00",  # date_filmed, truncated to a date
    "8.25",  # median_km
    "12",  # n (neighbours behind the median)
    "0.13519",  # mean_cos
]


NAMES = "slug ts source_ts lat lng travel_m state filmed median_km n mean_cos".split()


def one(**over):
    """The canonical row with named fields replaced."""
    f = list(FIELDS)
    for name, value in over.items():
        f[NAMES.index(name)] = value
    return "\t".join(f)


# The query and the unpack are coupled by position, so the count is asserted
# against the query text rather than trusted. The outer SELECT is the one whose
# projection reaches the client: it is the last one that names median_km beside
# the candidate columns.
def projected_columns():
    outer = max(
        (m for m in re.finditer(r"SELECT\s+(c\.slug.*?)\s+FROM", SCORE_SQL, re.S)),
        key=lambda m: m.start(),
    )
    return len([c for c in outer.group(1).split(",")])


assert projected_columns() == SCORE_COLUMNS, (
    f"SCORE_SQL projects {projected_columns()} columns, parse_scored unpacks "
    f"{SCORE_COLUMNS} -- a width parse_scored does not expect is discarded as "
    "an acknowledgement line, so the pool would come back empty"
)

# A well-formed row round-trips, with the two roundings and the date truncation.
(got,) = parse_scored(one(), k=10)
assert got == {
    "slug": "gs-classic",
    "ts": 12.5,
    "source_ts": 812.5,
    "lat": 41.8781,
    "lng": -87.6298,
    "radius_m": 40.0,
    "state": "Illinois",
    "filmed": "2019-06-01",
    "median_km": 8.2,  # rounded to 1dp: 8.25 -> 8.2 (banker's rounding)
    "mean_cos": 0.1352,  # rounded to 4dp
}, got

# psql's own chatter is not a row, whatever it says.
assert parse_scored("SET\nsetseed\n \n(3 rows)\n", k=10) == []

# The arity guard, from both sides. This is the case that motivates the
# assertion above: a row one column wide of the unpack is silently dropped.
assert parse_scored(one() + "\textra", k=10) == []
assert parse_scored("\t".join(FIELDS[:-1]), k=10) == []

# Too few neighbours behind the median to trust it.
assert parse_scored(one(n="9"), k=10) == []
assert len(parse_scored(one(n="10"), k=10)) == 1, "k is a floor, not a threshold"

# A candidate with no median at all -- no neighbour survived the filter.
assert parse_scored(one(median_km=""), k=10) == []

# The circle is floored, so a stopped van still gets a radius a player can hit.
(floored,) = parse_scored(one(travel_m="1"), k=10)
assert floored["radius_m"] > 1, "MIN_RADIUS_M did not floor a near-zero travel"

# And capped, so an unanswerably wide round is dropped rather than widened.
assert parse_scored(one(travel_m="9999"), k=10, max_radius_m=500) == []
(kept,) = parse_scored(one(travel_m="400"), k=10, max_radius_m=500)
assert kept["radius_m"] == 400.0

# Best-first is the query's ORDER BY, so the parse must not reorder.
two = one(slug="tight", median_km="2.0") + "\n" + one(slug="loose", median_km="90.0")
assert [r["slug"] for r in parse_scored(two, k=10)] == ["tight", "loose"]

print(
    "ok: the scored pool is read in SCORE_SQL's column order, and the quality filters hold"
)
