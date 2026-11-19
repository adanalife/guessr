#!/usr/bin/env python3
"""Cover /api/stats against the real migrations: every number on the page for
a player with a finished day, a half-played day and a replayed one, and that
nobody else's plays are in any of them.
"""

import asyncio

from server.db import Sqlite
from server.stats import MISS_EDGES_KM, stats

ME, OTHER = "me-id", "other-id"
D1, D2, D3 = "2026-08-01", "2026-08-02", "2026-09-10"
STATES = ["CA", "CA", "OR", "", "WA"]


async def seeded() -> Sqlite:
    db = Sqlite().migrate()
    for date in (D1, D2):
        for pos in range(1, 6):
            image = f"{date}-{pos}.mp4"
            await db.execute(
                "INSERT INTO rounds (image, median_km, mean_cos, batch, slug, source_ts_sec, clip_ts_sec, radius_m)"
                " VALUES (?, 10, 0.07, 'test', 'slug', 20, 20, 60)",
                image,
            )
            await db.execute(
                "INSERT INTO round_days (date, position, image) VALUES (?, ?, ?)",
                date,
                pos,
                image,
            )
            await db.execute(
                "INSERT INTO answers (image, lat, lng, state, filmed) VALUES (?, 34, -118, ?, '2018-03-20')",
                image,
                STATES[pos - 1],
            )

    async def play(date, player, image, km, points):
        await db.execute(
            "INSERT INTO plays (date, player_id, image, km, points) VALUES (?, ?, ?, ?, ?)",
            date,
            player,
            image,
            km,
            points,
        )

    # D1 finished: one miss in each of the first five buckets.
    for pos, (km, points) in enumerate(
        [(1.0, 5000), (20.0, 4000), (100.0, 3000), (500.0, 2000), (1000.0, 1000)], 1
    ):
        await play(D1, ME, f"{D1}-{pos}.mp4", km, points)
    # D2 half played, and a replay of a D1 round on a date with no schedule.
    await play(D2, ME, f"{D2}-1.mp4", 3000.0, 0)
    await play(D2, ME, f"{D2}-2.mp4", 2.0, 4900)
    await play(D3, ME, f"{D1}-3.mp4", 50.0, 3500)
    # Somebody else, better at all of it.
    for pos in range(1, 6):
        await play(D1, OTHER, f"{D1}-{pos}.mp4", 0.1, 5000)
    return db


async def test_stats() -> None:
    db = await seeded()
    for bad in (None, {}, {"player_id": ""}, {"player_id": 7}, {"player_id": "x" * 65}):
        assert (await stats(db, bad)) == (400, {"error": "expected {player_id}"}), bad
    assert await stats(db, {"player_id": "stranger"}) == (200, {"rounds": 0})

    status, s = await stats(db, {"player_id": ME})
    assert status == 200
    assert s == {
        "rounds": 8,
        "games": 3,
        "finished": 1,
        "first": D1,
        "points": 23400,
        "streak": 1,
        "streak_date": D1,
        "longest": 1,
        "avg_round": 2925,
        "avg_game": 15000,
        "median_km": 75.0,
        "best_game": {"date": D1, "points": 15000},
        "best_round": {"date": D1, "km": 1.0, "points": 5000, "state": "CA"},
        "worst_round": {"date": D2, "km": 3000.0, "points": 0, "state": "CA"},
        "miss_edges_km": [8.0, 80.5, 321.9, 804.7, 1609.3],
        # 1 and 2 km; 20 and 50; 100; 500; 1000; 3000.
        "misses": [2, 2, 1, 1, 1, 1],
        # Hardest first, and the round with no state is in none of them.
        "by_state": [
            {"state": "WA", "rounds": 1, "points": 1000},
            {"state": "OR", "rounds": 2, "points": 3250},
            {"state": "CA", "rounds": 4, "points": 3475},
        ],
        # The replay has no position, so position 3 is D1's play alone.
        "by_position": [
            {"position": 1, "rounds": 2, "points": 2500},
            {"position": 2, "rounds": 2, "points": 4450},
            {"position": 3, "rounds": 1, "points": 3000},
            {"position": 4, "rounds": 1, "points": 2000},
            {"position": 5, "rounds": 1, "points": 1000},
        ],
        "months": [
            {"month": "2026-08", "points": 19900, "games": 2},
            {"month": "2026-09", "points": 3500, "games": 1},
        ],
    }, s
    assert sum(s["misses"]) == s["rounds"]
    assert len(s["misses"]) == len(MISS_EDGES_KM) + 1

    # No finished day: the per-game numbers are absent, not zero.
    await db.execute("DELETE FROM plays WHERE player_id = ? AND date = ?", ME, D1)
    _, s = await stats(db, {"player_id": ME})
    assert (s["finished"], s["avg_game"], s["best_game"], s["longest"]) == (
        0,
        None,
        None,
        0,
    ), s
    assert (s["streak"], s["streak_date"]) == (0, None), s


asyncio.run(test_stats())
print("ok: /api/stats sums one player's plays, and only theirs")
