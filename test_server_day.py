#!/usr/bin/env python3
"""Cover the Python /api/day against the real migrations: the whole gate against
reading ahead, so which dates answer and with what. The same cases test_day.mjs
holds the JavaScript to.
"""

import asyncio
import datetime as dt

from server.day import day
from server.db import Sqlite
from server.score import score

NOW = dt.datetime(2026, 8, 5, 12, tzinfo=dt.UTC)
PAST = ["2026-08-01", "2026-08-02", "2026-08-03"]
OPEN = "2026-08-05"
FUTURE = "2099-06-01"


def image(date: str, i: int) -> str:
    return f"clips/{date.replace('-', '')}_{i}-0{i}0000.mp4"


async def seeded(dates=(*PAST, OPEN, FUTURE)) -> Sqlite:
    db = Sqlite().migrate()
    for date in dates:
        for i in range(1, 6):
            await db.execute(
                """INSERT INTO rounds (image, median_km, mean_cos, batch, slug, source_ts_sec,
                                       clip_ts_sec, radius_m)
                   VALUES (?, 10, 0.07, 'test', 'slug', 20, 20, 60)""",
                image(date, i),
            )
            await db.execute(
                "INSERT INTO answers (image, lat, lng, state, filmed) "
                "VALUES (?, 40, -100, 'KS', '2020-01-01')",
                image(date, i),
            )
            await db.execute(
                "INSERT INTO round_days (date, position, image) VALUES (?, ?, ?)",
                date,
                i,
                image(date, i),
            )
    return db


async def test_day() -> None:
    db = await seeded()

    def get(**q):
        return day(db, q, NOW)

    status, body, headers = await get(date=PAST[0])
    assert status == 200 and body["date"] == PAST[0]
    # Image names only, in position order: a SELECT * would leak nothing today
    # and everything the day a column is added.
    assert body["rounds"] == [{"image": image(PAST[0], i)} for i in range(1, 6)]
    assert "max-age=86400" in headers["cache-control"]
    status, _, headers = await get(date=OPEN)
    assert status == 200, "an open date did not read"
    assert headers["cache-control"] == "no-store", "an open date's rounds cached"

    status, body, _ = await get(date=FUTURE)
    assert status == 403 and "not opened" in body["error"] and "rounds" not in body
    assert (await get(date="2020-01-01"))[0] == 404, (
        "an unscheduled past date is 404, not 403"
    )
    for bad in (None, "", "2026-8-1", "yesterday", "2026-08-01T00:00", "2026-02-31"):
        assert (await get(date=bad))[0] == 400, bad
    assert (await get())[0] == 400

    served = set()
    for _ in range(20):
        status, body, headers = await get(practice="")
        assert (
            status == 200
            and body["date"] is None
            and headers["cache-control"] == "no-store"
        )
        assert 0 < len(body["rounds"]) <= 5
        served |= {r["image"] for r in body["rounds"]}
    assert served <= {image(d, i) for d in PAST for i in range(1, 6)}, (
        "practice served an unplayed round"
    )

    empty = Sqlite().migrate()
    assert (await day(empty, {"practice": ""}, NOW))[0] == 404


async def test_replay() -> None:
    """A date the schedule never reached replays one whole finished day, the
    same one on every request, and /api/score takes its rounds."""
    dry = "2026-08-06"  # open at NOW, nothing scheduled
    db = await seeded(PAST)
    status, body, _ = await day(db, {"date": dry}, NOW)
    assert status == 200, (status, body)
    assert body["rounds"] in [
        [{"image": image(d, i)} for i in range(1, 6)] for d in PAST
    ], "a replay is not one finished day, whole and in order"
    assert (await day(db, {"date": dry}, NOW))[1] == body, "a replay moved"

    play = {"date": dry, "player_id": "p1", "lat": 40, "lng": -100}
    status, scored = await score(db, {**play, "image": body["rounds"][0]["image"]}, NOW)
    assert status == 200 and scored["recorded"], (status, scored)
    other = next(
        image(d, 1) for d in PAST if {"image": image(d, 1)} not in body["rounds"]
    )
    assert (await score(db, {**play, "image": other}, NOW))[0] == 403

    # A short day is the schedule's own answer, not a cue to replay.
    await db.execute("DELETE FROM round_days WHERE date = ? AND position = 5", PAST[0])
    short = await day(db, {"date": PAST[0]}, NOW)
    assert len(short[1]["rounds"]) == 4, short

    # A year-old day wins over a recent one, so a replay is not last week's game.
    db = await seeded((*PAST, "2025-07-01"))
    _, body, _ = await day(db, {"date": dry}, NOW)
    assert body["rounds"][0]["image"] == image("2025-07-01", 1), body


asyncio.run(test_day())
asyncio.run(test_replay())
print(
    "ok: the Python /api/day matches the contract test_day.mjs holds, and replays a dry date"
)
