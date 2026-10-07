#!/usr/bin/env python3
"""Cover /api/wrapped against the real migrations: a player's month and year
totals, closest and furthest rounds, best and worst state, and the rank the
monthly board would print -- and nobody else's plays leaking in.
"""

import asyncio

from server.db import Sqlite
from server.wrapped import wrapped

ME, RIVAL, TIED = "me-id", "rival-id", "aaa-id"

# image -> answer state
ANSWERS = {"ca1": "CA", "ca2": "CA", "nv1": "NV", "nv2": "NV", "ut1": "UT"}

# (player, date, image, km, points)
PLAYS = [
    (ME, "2026-03-01", "ca1", 2.0, 5000),
    (ME, "2026-03-01", "ca2", 10.0, 4000),
    (ME, "2026-03-02", "nv1", 300.0, 1000),
    (ME, "2026-03-02", "nv2", 500.0, 500),
    (ME, "2026-03-03", "ut1", 900.0, 100),  # one UT round: never a best/worst state
    (ME, "2026-04-01", "ca1", 1.0, 5000),  # another month
    (RIVAL, "2026-03-01", "ca1", 0.5, 9000),
    (TIED, "2026-03-01", "ca1", 0.5, 4000),  # 10600 for March, level with ME
    (TIED, "2026-03-02", "nv1", 0.5, 6600),
]


async def seeded() -> Sqlite:
    db = Sqlite().migrate()
    for image, state in ANSWERS.items():
        await db.execute(
            "INSERT INTO answers (image, lat, lng, state, filmed) VALUES (?, 0, 0, ?, '2018-03-20')",
            image,
            state,
        )
    for play in PLAYS:
        await db.execute(
            "INSERT INTO plays (player_id, date, image, km, points) VALUES (?, ?, ?, ?, ?)",
            *play,
        )
    return db


async def test_wrapped() -> None:
    db = await seeded()
    for bad in (
        None,
        {},
        {"player_id": ME},
        {"period": "2026-03"},
        {"player_id": ME, "period": "2026-13"},
        {"player_id": ME, "period": "2026-03-01"},
        {"player_id": ME, "period": 2026},
    ):
        assert (await wrapped(db, bad))[0] == 400, bad

    status, month = await wrapped(db, {"player_id": ME, "period": "2026-03"})
    assert status == 200, month
    assert (month["days"], month["rounds"], month["points"]) == (3, 5, 10600), month
    assert month["km"] == 1712.0 and month["avg_km"] == 1712.0 / 5, month
    assert month["bullseyes"] == 1, month
    assert month["best"] == {
        "date": "2026-03-01",
        "image": "ca1",
        "km": 2.0,
        "points": 5000,
        "state": "CA",
    }, month["best"]
    assert month["worst"]["image"] == "ut1", month["worst"]
    assert month["best_state"] == {"state": "CA", "rounds": 2, "km": 6.0}, month
    assert month["worst_state"]["state"] == "NV", month
    # RIVAL 9000 and ME 10600 and TIED 10600: ME and TIED tie on points, and the
    # board breaks it on player_id, which puts "aaa-id" first.
    assert (month["rank"], month["players"]) == (2, 3), month

    _, year = await wrapped(db, {"player_id": ME, "period": "2026"})
    assert (year["days"], year["rounds"], year["bullseyes"]) == (4, 6, 2), year
    assert year["best"]["date"] == "2026-04-01", year

    _, april = await wrapped(db, {"player_id": ME, "period": "2026-04"})
    assert april["best_state"] is None, "one state cannot be both best and worst"

    _, empty = await wrapped(db, {"player_id": ME, "period": "2025-12"})
    assert (empty["rounds"], empty["points"], empty["avg_km"]) == (0, 0, None), empty
    assert empty["best"] is None and empty["rank"] is None, empty

    _, stranger = await wrapped(db, {"player_id": "stranger", "period": "2026-03"})
    assert stranger["rounds"] == 0 and stranger["rank"] is None, stranger
    assert stranger["players"] == 3, "the board size is everyone's, not the caller's"


asyncio.run(test_wrapped())
print("ok: /api/wrapped sums a player's month and year, and ranks it like the board")
