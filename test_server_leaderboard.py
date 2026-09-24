#!/usr/bin/env python3
"""Cover the Python /api/leaderboard against the real migrations: who places, in
what order, under which name, and which span each board serves. The same cases
test_leaderboard.mjs holds the JavaScript to, on a fixed clock instead of the
wall one.
"""

import asyncio
import datetime as dt

from server import rules
from server.db import Sqlite
from server.leaderboard import DAILY, MONTHLY, label, leaderboard

NOW = dt.datetime(2026, 8, 20, 12, tzinfo=dt.UTC)
DAY = "2026-08-19"  # the last closed date at NOW
MONTH = "2026-08"


def db(rows) -> Sqlite:
    """rows: (date, player, image, points, handle[, played_at]). played_at is a
    plain string, so a test can hand-place rows in time."""
    d = Sqlite().migrate()
    for image in {r[2] for r in rows} | {"a.jpg"}:
        d.conn.execute(
            "INSERT INTO answers (image, lat, lng, state, filmed) "
            "VALUES (?, 34.0, -118.0, 'CA', '2018-03-20')",
            (image,),
        )
    for tick, (date, player, image, points, handle, *when) in enumerate(rows):
        d.conn.execute(
            "INSERT INTO plays (date, player_id, image, km, points, handle, played_at) "
            "VALUES (?, ?, ?, 1.0, ?, ?, ?)",
            (
                date,
                player,
                image,
                points,
                handle,
                *(when or [f"2026-08-01 12:00:{tick:02}"]),
            ),
        )
    return d


def board(d: Sqlite, sql: str, period: str) -> list:
    return [[r["name"], r["points"]] for r in d.conn.execute(sql, (period, 10))]


def test_names() -> None:
    # A reroll mid-day wins in both directions, so this is not pinning a sort.
    for first, second in [
        ("Winding Valley", "Amber Basin"),
        ("Amber Basin", "Winding Valley"),
    ]:
        d = db(
            [
                ("2026-08-01", "p1", "a.jpg", 100, first),
                ("2026-08-01", "p1", "b.jpg", 200, second),
            ]
        )
        assert board(d, DAILY, "2026-08-01") == [[second, 300]], f"{first} -> {second}"

    # The rename reaches back to a day that closed before it existed.
    d = db(
        [
            ("2026-07-30", "p1", "a.jpg", 100, "Amber Basin"),
            ("2026-08-01", "p1", "b.jpg", 100, "Winding Valley"),
        ]
    )
    assert board(d, DAILY, "2026-07-30") == [["Winding Valley", 100]]

    # A nameless play does not blank a name; no name anywhere still places.
    d = db(
        [
            ("2026-08-01", "p1", "a.jpg", 100, "Amber Basin"),
            ("2026-08-01", "p1", "b.jpg", 100, None),
        ]
    )
    assert board(d, DAILY, "2026-08-01") == [["Amber Basin", 200]]
    assert board(
        db([("2026-08-01", "p1", "a.jpg", 100, None)]), DAILY, "2026-08-01"
    ) == [[None, 100]]

    # An operator alias outranks the drawn name back through history; clearing it
    # hands the player back their own; the note is never served.
    d = db(
        [
            ("2026-08-01", "p1", "a.jpg", 100, "Amber Basin"),
            ("2026-08-02", "p1", "b.jpg", 200, "Winding Valley"),
            ("2026-08-02", "p2", "c.jpg", 50, "Dusty Lookout"),
        ]
    )
    d.conn.execute(
        "INSERT INTO players (player_id, alias, note) VALUES ('p1', 'Phil', 'secret')"
    )
    assert board(d, DAILY, "2026-08-01") == [["Phil", 100]]
    assert board(d, DAILY, "2026-08-02") == [["Phil", 200], ["Dusty Lookout", 50]]
    d.conn.execute("UPDATE players SET alias = NULL WHERE player_id = 'p1'")
    assert board(d, DAILY, "2026-08-02") == [
        ["Winding Valley", 200],
        ["Dusty Lookout", 50],
    ]
    assert "secret" not in str(board(d, DAILY, "2026-08-02"))

    # Same second, two rounds: insert order decides.
    when = "2026-08-01 12:00:00"
    d = db(
        [
            ("2026-08-01", "p1", "a.jpg", 100, "Amber Basin", when),
            ("2026-08-01", "p1", "b.jpg", 100, "Winding Valley", when),
        ]
    )
    assert board(d, DAILY, "2026-08-01") == [["Winding Valley", 200]]


def test_ranking() -> None:
    d = db(
        [
            ("2026-08-01", "p1", "a.jpg", 100, "Amber Basin"),
            ("2026-08-01", "p2", "a.jpg", 400, "Amber Basin"),
            ("2026-08-01", "p1", "b.jpg", 200, "Amber Basin"),
            ("2026-08-02", "p1", "a.jpg", 900, "Amber Basin"),
            ("2026-07-31", "p1", "a.jpg", 500, "Amber Basin"),
        ]
    )
    assert board(d, DAILY, "2026-08-01") == [["Amber Basin", 400], ["Amber Basin", 300]]
    assert board(d, MONTHLY, "2026-08") == [["Amber Basin", 1200], ["Amber Basin", 400]]

    # Several players over several dates, so the planner has a reason to seek:
    # a scan here is invisible in the rows and shows up only as D1 rows-read.
    d = db(
        [
            (date, p, f"{p}-{date}.jpg", 100, f"Name {p}")
            for date in ("2026-08-01", "2026-08-02", "2026-08-03")
            for p in ("p1", "p2", "p3", "p4")
        ]
    )
    for sql, period in ((DAILY, "2026-08-01"), (MONTHLY, "2026-08")):
        plan = "\n".join(
            r["detail"]
            for r in d.conn.execute(f"EXPLAIN QUERY PLAN {sql}", (period, 10))
        )
        assert "INDEX plays_by_player_recent" in plan, plan


def test_label() -> None:
    assert label(["Amber Basin", "Winding Valley", "Amber Basin"]) == [
        "Amber Basin (1)",
        "Winding Valley",
        "Amber Basin (2)",
    ]
    distinct = ["Amber Basin", "Winding Valley", "Lucky Overpass"]
    assert (
        label(distinct) == distinct
        and label([]) == []
        and label(["Amber Basin"]) == ["Amber Basin"]
    )
    assert label(["A B"] * 3) == ["A B (1)", "A B (2)", "A B (3)"]
    assert label(["A", "B", "A", "B"]) == ["A (1)", "B (1)", "A (2)", "B (2)"]
    assert label(["anonymous", "Amber Basin", "anonymous"]) == [
        "anonymous (1)",
        "Amber Basin",
        "anonymous (2)",
    ]
    longest = f"{max(rules.ADJECTIVES, key=len)} {max(rules.NOUNS, key=len)}"
    assert all(len(n) <= 25 for n in label([longest] * 10)), "too wide for a board row"


async def test_handler() -> None:
    d = db(
        [
            (DAY, "p1", "a.jpg", 100, "Amber Basin"),
            (DAY, "p2", "a.jpg", 400, "Winding Valley"),
            ("2026-08-15", "p3", "a.jpg", 900, "Lucky Overpass"),
            ("2020-01-01", "p4", "a.jpg", 4000, "Distant Shore"),
        ]
    )

    async def get(**q):
        return await leaderboard(d, q, NOW)

    daily_rows = [["Winding Valley", 400], ["Amber Basin", 100]]
    monthly_rows = [["Lucky Overpass", 900], *daily_rows]
    for q in ({"board": "daily"}, {}, {"other": "1"}):
        assert await get(**q) == (
            200,
            {"board": "daily", "period": DAY, "rows": daily_rows},
            {"cache-control": "public, max-age=60"},
        ), q
    assert (await get(board="monthly"))[:2] == (
        200,
        {"board": "monthly", "period": MONTH, "rows": monthly_rows},
    )
    for b in ("weekly", "Daily", "MONTHLY", "all", "daily' OR 1=1"):
        assert (await get(board=b))[:2] == (
            400,
            {"error": "board must be daily or monthly"},
        ), b

    status, body, headers = await get(board="daily", date="2020-01-01")
    assert (status, body["rows"]) == (200, [["Distant Shore", 4000]])
    assert headers["cache-control"] == "public, max-age=3600"
    assert (await get(board="daily", date="2019-06-15"))[1]["rows"] == []

    for q, error in [
        ({"board": "daily", "date": "2026-08-20"}, "date has not closed yet"),
        ({"board": "daily", "date": "2026-08-21"}, "date has not closed yet"),
        *(
            ({"board": "daily", "date": x}, "date must be YYYY-MM-DD")
            for x in ("2026-8-1", "2026-08", "yesterday", "2026-02-31", "")
        ),
        (
            {"board": "monthly", "date": "2020-01-01"},
            "date applies to the daily board only",
        ),
        (
            {"board": "daily", "month": "2020-01"},
            "month applies to the monthly board only",
        ),
        ({"board": "monthly", "month": "2026-09"}, "month has not started yet"),
        *(
            ({"board": "monthly", "month": m}, "month must be YYYY-MM")
            for m in ("2026-8", "2026-13", "2026-00", "2026-08-01", "august", "")
        ),
    ]:
        assert (await get(**q))[:2] == (400, {"error": error}), q

    status, body, headers = await get(board="monthly", month="2020-01")
    assert (
        body["rows"] == [["Distant Shore", 4000]]
        and headers["cache-control"] == "public, max-age=3600"
    )
    assert (await get(board="monthly", month="2019-06"))[1]["rows"] == []
    status, body, headers = await get(board="monthly", month=MONTH)
    assert (
        body["rows"] == monthly_rows
        and headers["cache-control"] == "public, max-age=60"
    )

    # The placeholder goes on before numbering, so nameless players number apart.
    nameless = db(
        [
            (DAY, "p1", "a.jpg", 300, None),
            (DAY, "p2", "a.jpg", 200, "Amber Basin"),
            (DAY, "p3", "a.jpg", 100, None),
        ]
    )
    assert (await leaderboard(nameless, {}, NOW))[1]["rows"] == [
        ["anonymous (1)", 300],
        ["Amber Basin", 200],
        ["anonymous (2)", 100],
    ]

    # Up to two days a month the last closed date is the month before, and the
    # daily board's players are absent from the monthly one.
    early = dt.datetime(2026, 9, 1, 12, tzinfo=dt.UTC)
    status, body, _ = await leaderboard(d, {"board": "monthly"}, early)
    assert (body["period"], body["rows"]) == ("2026-09", [])
    assert (await leaderboard(d, {}, early))[1]["period"] == "2026-08-31"


test_names()
test_ranking()
test_label()
asyncio.run(test_handler())
print("ok: the Python /api/leaderboard matches the contract test_leaderboard.mjs holds")
