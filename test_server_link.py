#!/usr/bin/env python3
"""Cover the Python /api/link against the real migrations. A merge rewrites a
player's history, so these are about what it must never do: leave a round
counted twice, overwrite a score on record, or reach a player who was not part
of it. The same cases test_link.mjs holds the JavaScript to.
"""

import asyncio
import sqlite3

from server.db import Sqlite
from server.link import link

PHONE, DESKTOP, STRANGER = "phone-id", "desktop-id", "stranger-id"


async def plays(rows) -> Sqlite:
    db = Sqlite().migrate()
    for _, img, _ in rows:
        await db.execute(
            "INSERT OR IGNORE INTO answers (image, lat, lng, state, filmed) VALUES (?, 34, -118, 'CA', '2018-03-20')",
            img,
        )
    for player, img, points in rows:
        await db.execute(
            "INSERT INTO plays (date, player_id, image, km, points) VALUES ('2026-08-02', ?, ?, 1.0, ?)",
            player,
            img,
            points,
        )
    return db


async def owned(db, player) -> list[tuple]:
    rows = await db.fetchall(
        "SELECT image, points FROM plays WHERE player_id = ? ORDER BY image", player
    )
    return [(r["image"], r["points"]) for r in rows]


async def test_link() -> None:
    merge = {"from": PHONE, "to": DESKTOP}

    db = await plays(
        [(PHONE, "a.jpg", 100), (PHONE, "b.jpg", 200), (DESKTOP, "c.jpg", 300)]
    )
    assert await link(db, merge) == (200, {"moved": 2})
    assert await owned(db, PHONE) == []
    assert await owned(db, DESKTOP) == [("a.jpg", 100), ("b.jpg", 200), ("c.jpg", 300)]

    # Both devices answered one round: the score on record under the target wins,
    # and the loser is gone rather than left counting twice under the old id.
    db = await plays([(PHONE, "a.jpg", 4000), (DESKTOP, "a.jpg", 10)])
    assert await link(db, merge) == (200, {"moved": 0})
    assert await owned(db, DESKTOP) == [("a.jpg", 10)]
    assert await owned(db, PHONE) == []

    db = await plays(
        [(PHONE, "a.jpg", 100), (STRANGER, "a.jpg", 500), (STRANGER, "b.jpg", 500)]
    )
    await link(db, merge)
    assert await owned(db, STRANGER) == [("a.jpg", 500), ("b.jpg", 500)], (
        "the merge reached a bystander"
    )

    db = await plays([(PHONE, "a.jpg", 100)])
    assert await link(db, {"from": PHONE, "to": PHONE}) == (200, {"moved": 0})
    assert await owned(db, PHONE) == [("a.jpg", 100)], (
        "a self-link deleted its own plays"
    )

    for bad in (
        None,
        [],
        {},
        {"from": PHONE},
        {"from": PHONE, "to": ""},
        {"from": 1, "to": DESKTOP},
    ):
        assert (await link(db, bad))[0] == 400, bad


async def test_batch_is_one_transaction() -> None:
    # The seam's promise link depends on: a failing second statement undoes the
    # first, or a half-applied merge drops plays instead of moving them.
    db = await plays([(PHONE, "a.jpg", 100)])
    try:
        await db.batch([("DELETE FROM plays",), ("INSERT INTO nowhere VALUES (1)",)])
    except sqlite3.OperationalError:
        pass
    else:
        raise AssertionError("a batch with a broken statement succeeded")
    assert await owned(db, PHONE) == [("a.jpg", 100)], "the batch half-applied"


asyncio.run(test_link())
asyncio.run(test_batch_is_one_transaction())
print("ok: the Python /api/link matches the contract test_link.mjs holds")
