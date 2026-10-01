#!/usr/bin/env python3
"""Cover the Python /api/progress against the real migrations: a player's rounds
on a date come back in dealt order with the score on record, and nobody
else's do.
"""

import asyncio

from server.db import Sqlite
from server.progress import progress

DATE, PHONE, DESKTOP = "2026-08-02", "phone-id", "desktop-id"


async def seeded() -> Sqlite:
    db = Sqlite().migrate()
    for i in (1, 2, 3):
        await db.execute(
            "INSERT INTO rounds (image, median_km, mean_cos, batch, slug, source_ts_sec, clip_ts_sec, radius_m)"
            " VALUES (?, 10, 0.07, 'test', 'slug', 20, 20, 60)",
            f"{i}.mp4",
        )
        await db.execute(
            "INSERT INTO round_days (date, position, image) VALUES (?, ?, ?)",
            DATE,
            i,
            f"{i}.mp4",
        )
        await db.execute(
            "INSERT INTO answers (image, lat, lng, state, filmed) VALUES (?, 34, -118, 'CA', '2018-03-20')",
            f"{i}.mp4",
        )
    # Dealt 1, 2, 3; inserted out of order so the ORDER BY is what sorts them.
    for player, img, points, guess in (
        (PHONE, "2.mp4", 200, (41, -100)),
        (PHONE, "1.mp4", 100, (40, -100)),
        (DESKTOP, "1.mp4", 5000, (34, -118)),
    ):
        await db.execute(
            "INSERT INTO plays (date, player_id, image, km, points, guess_lat, guess_lng)"
            " VALUES (?, ?, ?, 1.5, ?, ?, ?)",
            DATE,
            player,
            img,
            points,
            *guess,
        )
    return db


async def test_progress() -> None:
    db = await seeded()
    for bad in (
        None,
        {},
        {"date": DATE},
        {"player_id": PHONE},
        {"date": "2026-13-01", "player_id": PHONE},
    ):
        assert (await progress(db, bad))[0] == 400, bad

    status, body = await progress(db, {"date": DATE, "player_id": PHONE})
    assert status == 200 and body["date"] == DATE
    assert [r["image"] for r in body["rounds"]] == ["1.mp4", "2.mp4"], body
    first = body["rounds"][0]
    assert first == {
        "image": "1.mp4",
        "km": 1.5,
        "points": 100,
        "guess_lat": 40,
        "guess_lng": -100,
        "lat": 34,
        "lng": -118,
        "state": "CA",
        "filmed": "2018-03-20",
    }, first

    _, other = await progress(db, {"date": "2026-08-03", "player_id": PHONE})
    assert other["rounds"] == [], "a date the player never played has rounds"
    _, nobody = await progress(db, {"date": DATE, "player_id": "stranger"})
    assert nobody["rounds"] == [], "a stranger sees plays"


asyncio.run(test_progress())
print("ok: /api/progress answers a player's own rounds in dealt order")
