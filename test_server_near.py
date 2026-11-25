#!/usr/bin/env python3
"""Cover /api/near against the real migrations: which rounds come back for a
point and in what order, what the field's numbers are, and -- the security
property -- that a round on a date still open is not among them.
"""

import asyncio
import datetime as dt

from server.db import Sqlite
from server.near import near

NOW = dt.datetime(2026, 8, 20, 12, tzinfo=dt.UTC)
DAY = "2026-08-19"  # the last closed date at NOW
TODAY = "2026-08-20"  # open
EARLIER = "2020-01-01"

LA = {"lat": "34.0", "lng": "-118.0"}


def seeded() -> Sqlite:
    d = Sqlite().migrate()
    c = d.conn
    for image, lat, lng, date, pos in [
        ("la.mp4", 34.11, -118.21, DAY, 1),
        ("sf.mp4", 37.77, -122.42, DAY, 2),
        ("denver.mp4", 39.74, -104.99, EARLIER, 1),
        # The closest of all to LA, and still open.
        ("open.mp4", 34.0, -118.0, TODAY, 1),
    ]:
        c.execute(
            "INSERT INTO answers (image, lat, lng, state, filmed) VALUES (?, ?, ?, 'CA', '2018-03-20')",
            (image, lat, lng),
        )
        c.execute(
            "INSERT INTO rounds (image, median_km, mean_cos, batch, slug, source_ts_sec, clip_ts_sec, "
            "radius_m) VALUES (?, 1.0, 0.1, 'test', 'slug', 0, 0, 100)",
            (image,),
        )
        c.execute(
            "INSERT INTO round_days (date, position, image) VALUES (?, ?, ?)",
            (date, pos, image),
        )
    for row in [
        (DAY, "p1", "la.mp4", 1.0, 4800),
        (DAY, "p2", "la.mp4", 4.0, 4000),
        (DAY, "p1", "sf.mp4", 250.0, 900),
        (TODAY, "p1", "open.mp4", 3.3, 4500),
        # The same clip replayed under another date is not that round's field.
        (EARLIER, "p3", "la.mp4", 900.0, 100),
    ]:
        c.execute(
            "INSERT INTO plays (date, player_id, image, km, points) VALUES (?, ?, ?, ?, ?)",
            row,
        )
    return d


async def test_near() -> None:
    d = seeded()

    async def get(**q):
        return await near(d, q, NOW)

    status, body, headers = await get(**LA)
    assert (status, headers["cache-control"]) == (200, "public, max-age=60")
    assert [r["image"] for r in body["rows"]] == ["la.mp4", "sf.mp4", "denver.mp4"], (
        body
    )
    assert "open.mp4" not in str(body)
    assert body["rows"][0] == {
        "date": DAY,
        "position": 1,
        "image": "la.mp4",
        "lat": 34.11,
        "lng": -118.21,
        "state": "CA",
        "filmed": "2018-03-20",
        "plays": 2,
        "avg_km": 2.5,
        "km": 22.9,
    }, body["rows"][0]
    # A round nobody played is still history: no plays, no average.
    assert (body["rows"][2]["plays"], body["rows"][2]["avg_km"]) == (0, None), body
    assert "player_id" not in str(body)

    # Asked from Denver, the order turns over; n cuts it.
    status, body, _ = await get(lat="39.7", lng="-105.0", n="1")
    assert [r["image"] for r in body["rows"]] == ["denver.mp4"], body

    # Longitude is weighed by the latitude asked for: at 60N a degree east is
    # half a degree north, so the round 3 degrees east beats the one 2 north.
    c = d.conn
    for image, lat, lng, pos in [
        ("east.mp4", 60.0, 3.0, 3),
        ("north.mp4", 62.0, 0.0, 4),
    ]:
        c.execute(
            "INSERT INTO answers (image, lat, lng, state, filmed) VALUES (?, ?, ?, 'NO', '2018-03-20')",
            (image, lat, lng),
        )
        c.execute(
            "INSERT INTO rounds (image, median_km, mean_cos, batch, slug, source_ts_sec, clip_ts_sec, "
            "radius_m) VALUES (?, 1.0, 0.1, 'test', 'slug', 0, 0, 100)",
            (image,),
        )
        c.execute(
            "INSERT INTO round_days (date, position, image) VALUES (?, ?, ?)",
            (DAY, pos, image),
        )
    _, body, _ = await get(lat="60", lng="0", n="2")
    assert [r["image"] for r in body["rows"]] == ["east.mp4", "north.mp4"], body

    for q in [
        {},
        {"lat": "34"},
        {"lat": "91", "lng": "0"},
        {"lat": "34", "lng": "-181"},
        {"lat": "nan", "lng": "0"},
        {"lat": "inf", "lng": "0"},
        {"lat": "north", "lng": "0"},
    ]:
        assert (await get(**q))[:2] == (
            400,
            {"error": "lat must be -90..90 and lng -180..180"},
        ), q
    for n in ["0", "51", "2.5", "many"]:
        assert (await get(**LA, n=n))[:2] == (400, {"error": "n must be 1..50"}), n


asyncio.run(test_near())
print("ok: /api/near lists the closed rounds nearest a point, and no open one")
