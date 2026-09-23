#!/usr/bin/env python3
"""Cover the D1 adapter against a stand-in binding with D1's call shape --
`prepare(sql).bind(*args)` then `first()` / `all()` / `run()`, and
`batch([...])` as one transaction -- backed by sqlite3 over the real migrations.

What is pinned is the translation: a row and a missing row, `results`, `meta.
changes`, and a batch that fails partway leaving nothing behind. The stand-in
models the binding, not D1; whether the SDK carries each Python value across is
the first staging deploy's to answer.
"""

import asyncio
import datetime as dt
import sqlite3

from server.admin_auth import Caller
from server.admin_day import preview, review
from server.d1 import D1
from server.db import Sqlite


class Statement:
    def __init__(self, conn, sql, args=()):
        self.conn, self.sql, self.args = conn, sql, args

    def bind(self, *args):
        # D1 refuses a statement bound twice; so does this.
        assert not self.args, "bound twice"
        return Statement(self.conn, self.sql, args)

    def _run(self):
        return self.conn.execute(self.sql, self.args)

    async def first(self):
        row = self._run().fetchone()
        return dict(row) if row else None

    async def all(self):
        return {"results": [dict(r) for r in self._run()], "meta": {"changes": 0}}

    async def run(self):
        return {"results": [], "meta": {"changes": self._run().rowcount}}


class Binding:
    def __init__(self, conn):
        self.conn = conn

    def prepare(self, sql):
        return Statement(self.conn, sql)

    async def batch(self, statements):
        with self.conn:
            self.conn.execute("BEGIN")
            return [await s.run() for s in statements]


NOW = dt.datetime(2026, 8, 5, 12, tzinfo=dt.UTC)
DAY = "2099-06-01"
OWNER = Caller("owner", "111", "dana")


def seeded() -> Sqlite:
    d = Sqlite().migrate()
    for i in range(1, 6):
        image = f"clips/r{i}-0{i}0000.mp4"
        d.conn.execute(
            "INSERT INTO rounds (image, median_km, mean_cos, batch, status, slug, source_ts_sec, "
            "clip_ts_sec, radius_m) VALUES (?, 1.0, 0.1, 'test', 'scheduled', 'slug', 0, 0, 100)",
            (image,),
        )
        d.conn.execute(
            "INSERT INTO round_days (date, position, image) VALUES (?, ?, ?)",
            (DAY, i, image),
        )
    return d


async def main() -> None:
    d = seeded()
    db = D1(Binding(d.conn))

    # The seam's four shapes, each against what Sqlite answers for the same call.
    q = "SELECT position, image FROM round_days WHERE date = ? ORDER BY position"
    assert await db.fetchall(q, DAY) == await d.fetchall(q, DAY)
    assert await db.fetchone(q, DAY) == {"position": 1, "image": "clips/r1-010000.mp4"}
    assert await db.fetchone(q, "1999-01-01") is None, "a missing row was not None"
    assert await db.fetchone("SELECT COUNT(*) AS n FROM rounds") == {"n": 5}, "unbound"
    changed = await db.execute(
        "UPDATE rounds SET status = 'queued' WHERE image LIKE ?", "%r5%"
    )
    assert changed == 1
    assert await db.batch(
        [
            ("UPDATE rounds SET status = 'scheduled' WHERE image LIKE ?", "%r5%"),
            ("UPDATE rounds SET status = status",),
        ]
    ) == [1, 5]

    # One transaction: a statement failing partway leaves the earlier ones undone.
    try:
        await db.batch(
            [
                ("DELETE FROM round_days WHERE date = ?", DAY),
                ("INSERT INTO nowhere VALUES (1)",),
            ]
        )
    except sqlite3.OperationalError:
        pass
    else:
        raise AssertionError("the failing batch reported success")
    assert len(await db.fetchall(q, DAY)) == 5, "a failed batch half-applied"

    # A real handler, unchanged, over the adapter.
    status, body, _ = await preview(db, OWNER, {"date": DAY}, NOW)
    assert (status, [r["position"] for r in body["rounds"]]) == (200, [1, 2, 3, 4, 5])
    status, body, _ = await review(db, OWNER, {"date": DAY, "reviewed": True}, NOW)
    assert status == 200 and body["reviewed_at"], "review over D1 stored nothing"


asyncio.run(main())
print("ok: the D1 adapter answers every seam call the way Sqlite does")
