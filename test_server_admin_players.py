#!/usr/bin/env python3
"""Cover the Python player half of /admin against the real migrations: who may
read a note, that a note write never touches the published alias, that a total
arrives whole or not at all, and that a board row names the same player the
public drilldown does. The cases test_admin_players.mjs, test_admin_plays.mjs and
test_admin_board_note.mjs hold the JavaScript to, behind the Twitch gate.
"""

import asyncio
import datetime as dt

from server.admin_auth import Caller
from server.admin_players import (
    MAX_NOTE,
    board_note,
    group,
    note_player,
    players,
    plays,
    set_board_note,
)
from server.db import Sqlite
from server.guesses import guesses

NOW = dt.datetime(2026, 8, 4, 12, tzinfo=dt.UTC)
DAY = "2026-08-03"  # the last closed date at NOW, so the daily board
OWNER = Caller("owner", "111", "dana")
MOD = Caller("mod", "222", "friend")
REGULAR, NEWCOMER, THIRD = "player-regular", "player-newcomer", "player-third"
IMAGES = ["clips/a-010000.mp4", "clips/b-020000.mp4", "clips/c-030000.mp4"]


def seeded() -> Sqlite:
    """The regular plays two days, the newcomer one day but most recently -- so
    ordering by insertion or by points comes out wrong. On DAY the newcomer
    outscores the third player, who is the only one with a scheduled round."""
    d = Sqlite().migrate()
    c = d.conn
    for i, image in enumerate(IMAGES):
        c.execute(
            "INSERT INTO answers (image, lat, lng, state, filmed) VALUES (?, ?, ?, 'OR', '2018-06-12')",
            (image, 40.0 + i, -120.0 - i),
        )
    c.execute(
        "INSERT INTO rounds (image, median_km, mean_cos, batch, slug, source_ts_sec, clip_ts_sec, "
        "radius_m) VALUES (?, 1.0, 0.1, 'test', 'slug', 0, 0, 100)",
        (IMAGES[2],),
    )
    c.execute(
        "INSERT INTO round_days (date, position, image) VALUES (?, 1, ?)",
        (DAY, IMAGES[2]),
    )
    for row in [
        ("2026-08-01", REGULAR, IMAGES[0], 4000, "Amber Basin", "2026-08-01 10:00:00", None),
        ("2026-08-02", REGULAR, IMAGES[1], 3000, "Amber Basin", "2026-08-02 10:00:00", 41.5),
        (DAY, NEWCOMER, IMAGES[2], 2500, "Copper Vale", "2026-08-03 11:00:00", 42.5),
        (DAY, THIRD, IMAGES[2], 100, "Dusty Ford", "2026-08-03 10:00:00", 30.0),
    ]:  # fmt: skip
        c.execute(
            "INSERT INTO plays (date, player_id, image, km, points, handle, played_at, guess_lat, "
            "guess_lng) VALUES (?, ?, ?, 10.0, ?, ?, ?, ?, -121.0)",
            row,
        )
    return d


def rows(d: Sqlite, sql: str, *args):
    return d.conn.execute(sql, args).fetchall()


def note_of(d: Sqlite, player_id: str):
    r = rows(d, "SELECT note FROM players WHERE player_id = ?", player_id)
    return r[0][0] if r else None


async def test_gate() -> None:
    # Nobody gets 401 and a mod 403, before anything is read or written, and the
    # refusal carries none of what it declined.
    for who, code in ((None, 401), (MOD, 403)):
        d = seeded()
        calls = [
            players(d, who),
            note_player(d, who, {"player_id": REGULAR, "note": "leaked"}),
            plays(d, who, {"date": "nonsense"}),
            board_note(d, who, {"rank": "1"}, NOW),
            set_board_note(d, who, {"rank": "1"}, {"note": "leaked"}, NOW),
        ]
        for call in calls:
            status, body, headers = await call
            assert (status, headers["cache-control"]) == (code, "no-store")
            assert set(body) == {"error"}, f"a refusal carried {body}"
        assert rows(d, "SELECT COUNT(*) FROM players")[0][0] == 0, (
            "a refused write reached the table"
        )


async def test_players() -> None:
    d = seeded()
    status, body, headers = await players(d, OWNER)
    assert (status, headers["cache-control"]) == (200, "no-store")
    listed = body["players"]
    assert [p["player_id"] for p in listed] == [NEWCOMER, THIRD, REGULAR], (
        "not ordered by who played most recently"
    )
    regular = listed[2]
    assert (regular["days"], regular["points"], regular["name"], regular["note"]) == (
        2,
        7000,
        "Amber Basin",
        None,
    )

    # Round trip, then an emptied note clears to null rather than a blank.
    status, body, _ = await note_player(
        d, OWNER, {"player_id": REGULAR, "note": "Phil's roommate"}
    )
    assert (status, body["note"]) == (200, "Phil's roommate")
    assert (await players(d, OWNER))[1]["players"][2]["note"] == "Phil's roommate"
    assert (await note_player(d, OWNER, {"player_id": REGULAR}))[1]["note"] is None
    assert note_of(d, REGULAR) is None, "an emptied note was stored as a blank"

    # An id nobody played under is refused and leaves no row.
    assert (await note_player(d, OWNER, {"player_id": "nobody", "note": "x"}))[0] == 404
    assert not rows(d, "SELECT 1 FROM players WHERE player_id = 'nobody'")

    for bad in (
        {},
        {"player_id": ""},
        {"player_id": 42},
        {"player_id": REGULAR, "note": 7},
        {"player_id": REGULAR, "note": "x" * (MAX_NOTE + 1)},
        "not an object",
    ):
        assert (await note_player(d, OWNER, bad))[0] == 400, f"{bad!r} was accepted"
    assert note_of(d, REGULAR) is None, "a refused note reached the table"


async def test_alias_survives() -> None:
    # The alias is published; a note write must leave it exactly where it was,
    # on the row it creates and when the note is later cleared.
    d = seeded()
    d.conn.execute(
        "INSERT INTO players (player_id, alias) VALUES (?, 'Phil')", (REGULAR,)
    )
    await note_player(d, OWNER, {"player_id": REGULAR, "note": "met at the meetup"})
    await note_player(d, OWNER, {"player_id": REGULAR, "note": ""})
    assert (
        rows(d, "SELECT alias FROM players WHERE player_id = ?", REGULAR)[0][0]
        == "Phil"
    )
    regular = (await players(d, OWNER))[1]["players"][2]
    assert (regular["name"], regular["alias"]) == ("Phil", "Phil")

    # And through the board route too, which creates the row.
    await set_board_note(d, OWNER, {"rank": "2"}, {"note": "third"}, NOW)
    d.conn.execute("UPDATE players SET alias = 'Dusty' WHERE player_id = ?", (THIRD,))
    await set_board_note(d, OWNER, {"rank": "2"}, {"note": ""}, NOW)
    assert (
        rows(d, "SELECT alias FROM players WHERE player_id = ?", THIRD)[0][0] == "Dusty"
    )


async def test_plays() -> None:
    d = seeded()
    d.conn.execute(
        "INSERT INTO players (player_id, alias, note) VALUES (?, 'Copper', 'a friend')",
        (NEWCOMER,),
    )
    for bad in (None, "", "2026-8-3", "nonsense"):
        assert (await plays(d, OWNER, {"date": bad}))[0] == 400, f"{bad!r} accepted"

    status, body, headers = await plays(d, OWNER, {"date": DAY})
    assert (status, headers["cache-control"], body["date"]) == (200, "no-store", DAY)
    top, low = body["players"]
    assert [top["total"], low["total"]] == [2500, 100], "not highest total first"
    assert (top["name"], top["alias"], top["note"]) == ("Copper", "Copper", "a friend")
    assert top["rounds"] == [
        {
            "position": 1,
            "image": IMAGES[2],
            "state": "OR",
            "km": 10.0,
            "points": 2500,
            "guess_lat": 42.5,
            "guess_lng": -121.0,
            "lat": 42.0,
            "lng": -122.0,
        }
    ]
    # A play on an image never scheduled under its date still counts, position
    # null; one recorded before 0003 has no pin and invents none.
    early = (await plays(d, OWNER, {"date": "2026-08-01"}))[1]["players"][0]
    assert (early["total"], early["rounds"][0]["position"]) == (4000, None)
    assert early["rounds"][0]["guess_lat"] is None


def test_group() -> None:
    # The player the LIMIT cut into is dropped, not shown short.
    def row(player, points):
        return {
            "player_id": player,
            "name": player,
            "alias": None,
            "note": None,
            "points": points,
        } | dict.fromkeys(
            ("position", "image", "state", "km", "guess_lat", "guess_lng", "lat", "lng")
        )

    cut = [row("whole", 2500), row("whole", 2500), row("cut", 4000)]
    assert [p["player_id"] for p in group(cut, True)] == ["whole"]
    assert [p["total"] for p in group(cut, False)] == [5000, 4000]
    assert group([], True) == []


async def test_board_note() -> None:
    # THE ONE THAT MATTERS: a rank names the same player the drilldown beside it
    # names, or a private note lands on somebody else. Written through this
    # route, read back by id.
    d = seeded()
    for rank, player, other in (("1", NEWCOMER, THIRD), ("2", THIRD, NEWCOMER)):
        shown = (await guesses(d, {"board": "daily", "rank": rank}, NOW))[1]
        status, saved, headers = await set_board_note(
            d, OWNER, {"rank": rank}, {"note": f"note for {rank}"}, NOW
        )
        assert (status, headers["cache-control"]) == (200, "no-store")
        assert saved["name"] == shown["name"]
        assert note_of(d, player) == f"note for {rank}"
        assert note_of(d, other) != f"note for {rank}", "the note landed twice"

    # A write answers in exactly the shape the read after it gives.
    written = (
        await set_board_note(d, OWNER, {"rank": "1"}, {"note": "from the stream"}, NOW)
    )[1]
    read = (await board_note(d, OWNER, {"rank": "1"}, NOW))[1]
    assert (
        written
        == read
        == {
            "board": "daily",
            "period": DAY,
            "rank": 1,
            "name": "Copper Vale",
            "note": "from the stream",
        }
    )
    assert "player_id" not in read, "a board-addressed read handed out the id"

    # The monthly board addresses a player too.
    status, body, _ = await set_board_note(
        d,
        OWNER,
        {"board": "monthly", "rank": "1", "month": "2026-08"},
        {"note": "monthly regular"},
        NOW,
    )
    assert (status, body["name"]) == (200, "Amber Basin")
    assert note_of(d, REGULAR) == "monthly regular"


async def test_board_note_refusals() -> None:
    d = seeded()
    # A rank past the board names nobody and must not fall through to the last row.
    assert (await set_board_note(d, OWNER, {"rank": "3"}, {"note": "x"}, NOW))[0] == 404
    for params, body in (
        ({"rank": "0"}, {"note": "x"}),
        ({"rank": "abc"}, {"note": "x"}),
        ({"board": "weekly", "rank": "1"}, {"note": "x"}),
        ({"rank": "1"}, {"note": 7}),
        ({"rank": "1"}, {"note": "x" * (MAX_NOTE + 1)}),
    ):
        status, _, headers = await set_board_note(d, OWNER, params, body, NOW)
        assert (status, headers["cache-control"]) == (400, "no-store"), (
            f"{params} {body} accepted"
        )
    assert rows(d, "SELECT COUNT(*) FROM players")[0][0] == 0, (
        "a refused write left a row"
    )


async def main() -> None:
    await test_gate()
    await test_players()
    await test_alias_survives()
    await test_plays()
    test_group()
    await test_board_note()
    await test_board_note_refusals()


asyncio.run(main())
print(
    "ok: the Python player notes match the contract the admin player tests hold, behind Twitch"
)
