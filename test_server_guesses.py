#!/usr/bin/env python3
"""Cover the Python /api/guesses against the real migrations: which player a rank
resolves to, which plays come back, and -- the security property -- which
coordinates do not. The same cases test_guesses.mjs holds the JavaScript to, on
a fixed clock instead of the wall one.
"""

import asyncio
import datetime as dt

from server.db import Sqlite
from server.guesses import guesses

NOW = dt.datetime(2026, 8, 20, 12, tzinfo=dt.UTC)
DAY = "2026-08-19"  # the last closed date at NOW, and the daily board
TODAY = "2026-08-20"  # open, in the running month
EARLIER = "2020-01-01"


def seeded() -> Sqlite:
    d = Sqlite().migrate()
    c = d.conn
    # A distinct location per answer, somewhere no guess is, so a truth can't be
    # mistaken for its neighbour's or for the guess.
    for image, lat, lng in [
        ("a.mp4", 34.11, -118.21),
        ("b.mp4", 37.77, -122.42),
        ("c.mp4", 45.52, -122.68),
        ("d.mp4", 39.74, -104.99),
    ]:
        c.execute(
            "INSERT INTO answers (image, lat, lng, state, filmed) VALUES (?, ?, ?, 'CA', '2018-03-20')",
            (image, lat, lng),
        )
    for image in ("a.mp4", "b.mp4", "d.mp4"):
        c.execute(
            "INSERT INTO rounds (image, median_km, mean_cos, batch, slug, source_ts_sec, clip_ts_sec, "
            "radius_m) VALUES (?, 1.0, 0.1, 'test', 'slug', 0, 0, 100)",
            (image,),
        )
    # Today's play is left unscheduled: position null, row intact.
    for date, pos, image in [
        (DAY, 1, "a.mp4"),
        (DAY, 2, "b.mp4"),
        (EARLIER, 1, "d.mp4"),
    ]:
        c.execute(
            "INSERT INTO round_days (date, position, image) VALUES (?, ?, ?)",
            (date, pos, image),
        )
    for row in [
        (DAY, "p1", "a.mp4", 1.2, 4800, "Amber Basin", 34.1, -118.2),
        (DAY, "p1", "b.mp4", 250.0, 900, "Amber Basin", 36.0, -120.0),
        (DAY, "p2", "a.mp4", 9.0, 4000, "Winding Valley", 34.5, -118.5),
        (TODAY, "p1", "c.mp4", 3.3, 4500, "Amber Basin", 45.0, -122.0),
        # p2 alone on the older date, so its rank 1 cannot land on p1.
        (EARLIER, "p2", "d.mp4", 5.5, 3300, "Winding Valley", 40.0, -111.0),
    ]:
        c.execute(
            "INSERT INTO plays (date, player_id, image, km, points, handle, guess_lat, guess_lng) "
            "VALUES (?, ?, ?, ?, ?, ?, ?, ?)",
            row,
        )
    return d


async def test_guesses() -> None:
    d = seeded()

    async def get(**q):
        return await guesses(d, q, NOW)

    status, body, headers = await get(board="daily", rank="1")
    assert (status, headers["cache-control"]) == (200, "public, max-age=60")
    assert body == {
        "board": "daily",
        "period": DAY,
        "rank": 1,
        "name": "Amber Basin",
        "rows": [
            {
                "date": DAY,
                "position": 1,
                "km": 1.2,
                "points": 4800,
                "image": "a.mp4",
                "guess_lat": 34.1,
                "guess_lng": -118.2,
                "answer_lat": 34.11,
                "answer_lng": -118.21,
            },
            {
                "date": DAY,
                "position": 2,
                "km": 250.0,
                "points": 900,
                "image": "b.mp4",
                "guess_lat": 36.0,
                "guess_lng": -120.0,
                "answer_lat": 37.77,
                "answer_lng": -122.42,
            },
        ],
    }, body
    assert "player_id" not in str(body)

    status, body, _ = await get(board="daily", rank="2")
    assert (status, body["name"], len(body["rows"])) == (200, "Winding Valley", 1)
    assert (await get(board="daily", rank="3"))[:2] == (
        404,
        {"error": "no player at that rank"},
    )

    # The open date keeps distance and points and loses pin, clip and truth; the
    # closed day beside it keeps all three, so the guard is the date test.
    status, body, _ = await get(board="monthly", rank="1")
    assert (status, body["name"]) == (200, "Amber Basin")
    assert [r for r in body["rows"] if r["date"] == TODAY] == [
        {
            "date": TODAY,
            "position": None,
            "km": 3.3,
            "points": 4500,
            "image": None,
            "guess_lat": None,
            "guess_lng": None,
            "answer_lat": None,
            "answer_lng": None,
        }
    ]
    closed = [r for r in body["rows"] if r["date"] == DAY]
    assert len(closed) == 2 and all(
        r["image"] and r["guess_lat"] and r["answer_lat"] for r in closed
    )

    for q in ({"board": "weekly", "rank": "1"}, {"board": "Daily", "rank": "1"}):
        assert (await get(**q))[:2] == (
            400,
            {"error": "board must be daily or monthly"},
        ), q
    for rank in ("0", "11", "2.5", "abc", "", "-1", "1e0"):
        assert (await get(board="daily", rank=rank))[0] == 400, rank
    assert (await get())[0] == 400, "a missing rank was accepted"

    # Paging back resolves the rank against that date's standings, not today's.
    status, body, headers = await get(board="daily", rank="1", date=EARLIER)
    assert (status, body["name"], headers["cache-control"]) == (
        200,
        "Winding Valley",
        "public, max-age=3600",
    )
    assert body["rows"] == [
        {
            "date": EARLIER,
            "position": 1,
            "km": 5.5,
            "points": 3300,
            "image": "d.mp4",
            "guess_lat": 40.0,
            "guess_lng": -111.0,
            "answer_lat": 39.74,
            "answer_lng": -104.99,
        }
    ]
    status, _, headers = await get(board="daily", rank="2", date=EARLIER)
    assert (status, headers["cache-control"]) == (404, "public, max-age=3600")

    for q, error in [
        ({"date": TODAY}, "date has not closed yet"),
        ({"date": "9999-01-01"}, "date has not closed yet"),
        ({"date": "2026-2-3"}, "date must be YYYY-MM-DD"),
        ({"date": "2026-02-31"}, "date must be YYYY-MM-DD"),
        ({"board": "monthly", "date": EARLIER}, "date applies to the daily board only"),
    ]:
        assert (await get(**{"board": "daily", "rank": "1", **q}))[:2] == (
            400,
            {"error": error},
        ), q


asyncio.run(test_guesses())
print("ok: the Python /api/guesses matches the contract test_guesses.mjs holds")
