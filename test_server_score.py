#!/usr/bin/env python3
"""Cover the Python /api/score: the scoring curve, the guess and play validators,
the play window, and the handler's guards against a real schema.

The same cases test_score.mjs holds the JavaScript to, because both handlers
serve the same contract until the port is finished. Every one of these fails
silently if it breaks: a wrong distance still returns plausible points, and a
validator that lets a non-number through scores it as a perfect guess.

Also holds the two copies of what the Python cannot import from the page -- the
alias wordlists and the play-window hours -- identical to web/.
"""

import asyncio
import datetime as dt
import math
import re
from pathlib import Path

from server import rules
from server.db import Sqlite
from server.score import score

WEB = Path(__file__).parent / "web"
SF = {"lat": 37.7749, "lng": -122.4194}
NYC = {"lat": 40.7128, "lng": -74.0060}

# The copies agree with the page. A word only in the page's list is a name the
# server drops; an hour off by one is a play the page offers and this refuses.
alias_js = (WEB / "alias.js").read_text()
for name, words in (("ADJECTIVES", rules.ADJECTIVES), ("NOUNS", rules.NOUNS)):
    block = re.search(rf"export const {name} = \[(.*?)\];", alias_js, re.S).group(1)
    assert set(re.findall(r"'(\w+)'", block)) == words, (
        f"{name} differs from web/alias.js"
    )
daily_js = (WEB / "daily.js").read_text()
for name in ("OPENS_UTC_HOUR", "CLOSES_UTC_HOUR"):
    js = int(re.search(rf"const {name} = (\d+);", daily_js).group(1))
    assert js == getattr(rules, name), f"{name} differs from web/daily.js"

# ~4130 km great-circle; 1% covers the earth-radius choice.
sf_to_nyc = rules.haversine_km(SF, NYC)
assert abs(sf_to_nyc - 4130) < 41, sf_to_nyc
assert rules.haversine_km(SF, SF) == 0
assert rules.haversine_km(SF, NYC) == rules.haversine_km(NYC, SF)
assert rules.haversine_km({"lat": 0, "lng": 179}, {"lat": 0, "lng": -179}) < 250

assert rules.score_for(0) == rules.MAX_ROUND_SCORE
assert rules.score_for(sf_to_nyc) < 50
for near, far in ((0, 1), (1, 10), (10, 100), (100, 1000)):
    assert rules.score_for(near) > rules.score_for(far), (near, far)

good = {"image": "clips/a.mp4", "lat": 40, "lng": -100}
assert rules.parse_guess(good) == good
assert rules.parse_guess({**good, "extra": "ignored"}) == good
for bad in [
    None,
    "string",
    42,
    [],
    {},
    {**good, "lat": "40"},
    {**good, "lat": None},
    {**good, "lat": True},  # an int to Python, not a latitude
    {k: v for k, v in good.items() if k != "lng"},
    {**good, "lat": math.nan},  # Python's json accepts a bare NaN
    {**good, "lng": math.inf},
    {**good, "lat": 91},
    {**good, "lat": -91},
    {**good, "lng": 181},
    {**good, "lng": -181},
    {**good, "image": ""},
    {**good, "image": 42},
    {**good, "image": "x" * 201},
]:
    assert rules.parse_guess(bad) is None, bad
for edge in (
    {"lat": 90},
    {"lat": -90},
    {"lng": 180},
    {"lng": -180},
    {"lat": 0.0, "lng": 0},
):
    assert rules.parse_guess({**good, **edge}), edge

play = {"date": "2026-08-01", "player_id": "a3f1c2d4-0000-4000-8000-000000000000"}
assert rules.parse_play(play) == {
    "date": play["date"],
    "player_id": play["player_id"],
    "handle": None,
}
assert not rules.is_play(good)
assert rules.is_play(play)
assert rules.parse_play(good) is None
assert rules.is_play({**play, "date": "yesterday"})
assert rules.parse_play({**play, "date": "yesterday"}) is None
assert rules.is_play({**play, "date": None}), "a null date is still a play that failed"

alias = "Amber Arroyo"
assert rules.parse_play({**play, "handle": f"  {alias}  "})["handle"] == alias
for blank in ("", "   ", None):
    assert rules.parse_play({**play, "handle": blank})["handle"] is None
assert rules.parse_play({**play, "handle": 42}) is None
for forged in [
    "GO WATCH SOMEONE ELSE",
    "Jason",
    "Amber",
    "Arroyo Amber",
    "Amber Arroyo Basin",
    "Amber  Arroyo",
    "amber Arroyo",
    "<script>alert(1)</script>",
    "x" * 200,
]:
    kept = rules.parse_play({**play, "handle": forged})
    assert kept and kept["handle"] is None, forged
for adjective in rules.ADJECTIVES:
    for noun in rules.NOUNS:
        name = f"{adjective} {noun}"
        assert rules.parse_play({**play, "handle": name})["handle"] == name
        assert len(name) <= rules.MAX_HANDLE, name

for bad in [
    {**play, "date": "2026-8-1"},
    {**play, "date": "2026-13-01"},
    {**play, "date": "2026-01-32"},
    {**play, "date": "2026-02-31"},
    {**play, "date": "2026-02-29"},
    {**play, "date": "01-08-2026"},
    {**play, "date": "2026-08-01T00:00:00Z"},
    {**play, "date": "2026-08-01\n"},  # re.match's $ would let this through
    {**play, "date": "٢٠٢٦-٠٨-٠١"},  # Arabic-Indic digits, which \d matches
    {**play, "date": 20260801},
    {**play, "date": None},
    {**play, "player_id": ""},
    {**play, "player_id": 42},
    {**play, "player_id": "x" * 65},
    {"date": play["date"]},
]:
    assert rules.parse_play(bad) is None, bad
assert rules.parse_play({**play, "date": "2028-02-29"})


# The window's edges, in UTC: opens 10:00 the day before, closes 12:00 the day
# after, half-open.
def at(s: str) -> dt.datetime:
    return dt.datetime.fromisoformat(s).replace(tzinfo=dt.UTC)


assert not rules.is_open("2026-03-01", at("2026-02-28T09:59:59"))
assert rules.is_open("2026-03-01", at("2026-02-28T10:00:00"))
assert rules.is_open("2026-03-01", at("2026-03-02T11:59:59"))
assert not rules.is_open("2026-03-01", at("2026-03-02T12:00:00"))
assert rules.is_open("2026-12-31", at("2027-01-01T11:00:00")), (
    "the window crosses a year"
)


async def handler() -> None:
    db = Sqlite().migrate()
    mine, theirs, loose = (
        "clips/a-010000.mp4",
        "clips/b-020000.mp4",
        "clips/c-030000.mp4",
    )
    today = dt.datetime.now(dt.UTC).date().isoformat()
    other = (dt.datetime.now(dt.UTC).date() - dt.timedelta(days=5)).isoformat()
    for i, image in enumerate((mine, theirs, loose)):
        await db.execute(
            """INSERT INTO rounds (image, median_km, mean_cos, batch, slug, source_ts_sec,
                                   clip_ts_sec, radius_m)
               VALUES (?, 10, 0.07, 'test', 'slug', 20, 20, 60)""",
            image,
        )
        await db.execute(
            "INSERT INTO answers (image, lat, lng, state, filmed) VALUES (?, 40, -100, 'CA', '2018-01-01')",
            image,
        )
        if i < 2:
            await db.execute(
                "INSERT INTO round_days (date, position, image) VALUES (?, 1, ?)",
                (today, other)[i],
                image,
            )

    pid = "a3f1c2d4-0000-4000-8000-000000000000"

    def guess(image, date=None, lat=40.0, **extra):
        body = {"image": image, "lat": lat, "lng": -100, **extra}
        if date:
            body |= {"date": date, "player_id": pid}
        return score(db, body)

    assert (await score(db, None))[0] == 400, "an unparsed body is a 400"
    assert (await score(db, {**good, "date": "nope"}))[0] == 400
    assert (await guess("clips/none.mp4"))[0] == 404
    assert (await guess(mine, other))[0] == 403, "a closed date took a play"

    status, body = await guess(mine, today, handle="Amber Arroyo")
    assert status == 200 and body["recorded"] and body["points"] == 5000, body
    assert (body["lat"], body["lng"], body["state"], body["filmed"]) == (
        40,
        -100,
        "CA",
        "2018-01-01",
    )
    assert (await guess(theirs, today))[0] == 403, (
        "another date's round scored against today"
    )
    assert (await guess(loose, today))[0] == 403, "an unscheduled round was a play"

    # First write wins: a worse replay reports the stored score and writes nothing.
    status, replay = await guess(mine, today, lat=45.0)
    assert status == 200 and replay["points"] == 5000 and replay["km"] == 0, replay
    rows = await db.fetchall("SELECT handle, guess_lat, guess_lng FROM plays")
    assert rows == [{"handle": "Amber Arroyo", "guess_lat": 40, "guess_lng": -100}], (
        rows
    )

    status, practice = await guess(loose)
    assert status == 200 and practice["recorded"] is False, (
        "practice was gated on the schedule"
    )


asyncio.run(handler())
print("ok: the Python scorer matches the contract test_score.mjs holds")
