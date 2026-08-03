#!/usr/bin/env python3
"""Check how a round set is chosen from a scored pool. `python3 test_select.py`.

These two functions decide what the game actually is: rank() weighs the two
signals against each other and select() refuses a set that is the same place
twice. Both failed silently before they existed -- the shipped 300-round set
has California at twice its share of the corpus and 157 rounds within 5 km of
another one, and nothing reported it. So the properties are pinned here rather
than eyeballed off a contact sheet.
"""

from make_rounds import rank, select

# median_km: lower is more locatable. mean_cos: higher is more distinctive.
POOL = [
    {"slug": "both", "median_km": 10, "mean_cos": 0.14},
    {"slug": "locatable", "median_km": 5, "mean_cos": 0.05},
    {"slug": "distinct", "median_km": 200, "mean_cos": 0.15},
    {"slug": "neither", "median_km": 210, "mean_cos": 0.04},
]


def order(weight):
    return [r["slug"] for r in rank(POOL, weight)]


# All the way to either end, one signal decides and the other is ignored.
assert order(0.0)[0] == "locatable", order(0.0)
assert order(0.0)[-1] == "neither", order(0.0)
assert order(1.0)[0] == "distinct", order(1.0)

# In between, a clip that is good at both beats one that is excellent at one and
# worst at the other. This is the whole point of combining them: `locatable` is
# the most locatable clip in the pool and still loses, because being locatable
# while looking like every other stretch of road is what the old ordering kept
# rewarding.
assert order(0.5)[0] == "both", order(0.5)
assert order(0.5)[-1] == "neither", order(0.5)


def at(slug, lat, lng, state="CA"):
    return {"slug": slug, "lat": lat, "lng": lng, "state": state}


# 0.05 degrees of latitude is ~5.6 km, 0.01 is ~1.1 km.
FAR, NEAR = 0.05, 0.01

# The near twin of an already-taken round is skipped, and the next well-spread
# candidate is taken in its place -- rank order decides which of a close pair
# survives, so the better round is the one that stays.
chosen, backfilled = select(
    [at("best", 40, -100), at("twin", 40 + NEAR, -100), at("far", 41, -100)],
    count=2,
    min_km=5.0,
    state_cap=0,
)
assert [r["slug"] for r in chosen] == ["best", "far"], chosen
assert backfilled == 0

# When the pool runs out of spread before it runs out of rounds, the set is
# filled anyway and says how many are crowded. Returning short would change the
# repeat rate of the daily draw, which is a worse failure than a close pair.
chosen, backfilled = select(
    [at("a", 40, -100), at("b", 40 + NEAR, -100), at("c", 40 + 2 * NEAR, -100)],
    count=3,
    min_km=5.0,
    state_cap=0,
)
assert len(chosen) == 3 and backfilled == 2, (chosen, backfilled)

# Spacing off means no round is ever skipped for being close.
assert select([at("a", 40, -100), at("b", 40 + NEAR, -100)], 2, 0, 0)[1] == 0

# The state cap bites, and it is not relaxed by the backfill -- a set that can
# only be filled by breaking it comes out short instead, because the cap is the
# only thing damping the corpus's own lean.
spread_out = [at(f"ca{i}", 40 + i * FAR, -100, "CA") for i in range(5)]
chosen, backfilled = select(spread_out, count=5, min_km=5.0, state_cap=2)
assert len(chosen) == 2, chosen
assert backfilled == 0, backfilled

# With somewhere else to go, the cap redirects rather than truncates.
chosen, _ = select(
    spread_out + [at("me", 45, -70, "ME"), at("tx", 31, -97, "TX")],
    count=4,
    min_km=5.0,
    state_cap=2,
)
assert sorted(r["state"] for r in chosen) == ["CA", "CA", "ME", "TX"], chosen

# A round is never taken twice, even when the backfill pass revisits the list.
chosen, _ = select([at("only", 40, -100)], count=5, min_km=5.0, state_cap=0)
assert [r["slug"] for r in chosen] == ["only"], chosen


def moment(ts, median_km, mean_cos):
    # Moments of one clip share its coordinates -- they are the same video row.
    return {
        "slug": "clip",
        "ts": ts,
        "median_km": median_km,
        "mean_cos": mean_cos,
        "lat": 40,
        "lng": -100,
        "state": "CA",
    }


# `--per-clip` scores several moments of the same clip, so a slug arrives more
# than once at different timestamps and different scores. Nothing dedupes them
# explicitly: select() skips a slug it has taken, so the moment that survives is
# whichever ranked highest -- which is what makes a clip contribute its best
# moment rather than whichever one the draw happened to land on. Measured on the
# stage corpus, one clip's four moments ranged 15.7 to 58.3 median km, so the
# difference between best and drawn-at-random is most of the quality of a round.
MOMENTS = [
    moment(20.0, 300, 0.04),
    moment(50.0, 8, 0.14),  # the best of them on both signals
    moment(80.0, 250, 0.05),
    {
        "slug": "other",
        "ts": 30.0,
        "median_km": 150,
        "mean_cos": 0.09,
        "lat": 45,
        "lng": -70,
        "state": "ME",
    },
]
chosen, _ = select(rank(MOMENTS, 0.25), count=4, min_km=5.0, state_cap=0)
assert [r["slug"] for r in chosen] == ["clip", "other"], chosen
assert chosen[0]["ts"] == 50.0, chosen[0]

# The same three moments with the best one ranked last by both signals: the
# survivor tracks rank rather than input order, so this is not passing by
# accident of list position.
reordered = [moment(20.0, 8, 0.14), moment(50.0, 300, 0.04), moment(80.0, 250, 0.05)]
chosen, _ = select(rank(reordered, 0.25), count=3, min_km=5.0, state_cap=0)
assert [r["ts"] for r in chosen] == [20.0], chosen

print("ok: ranking weighs locatability against distinctiveness as intended")
print("ok: selection spaces the set out, caps one state, and backfills honestly")
print("ok: a clip scored at several moments contributes only its best one")
