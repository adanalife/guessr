#!/usr/bin/env python3
"""Cover the answer key's seed script and the constraint that now guards it.

`plays.image` references `answers(image)` (migration 0004), so the seed script's
write now runs against a constraint. It emits an ON CONFLICT upsert rather than
INSERT OR REPLACE, which reads like the same statement and is not: REPLACE is a
DELETE followed by an INSERT. That happens to survive the constraint as written
-- no ON DELETE action, checked at end of statement, row already back -- but
under an ON DELETE CASCADE the identical statement silently deletes the plays
instead, with no error. Neither difference is visible in the SQL.

So the properties are asserted against stdlib sqlite3 with the real migrations
replayed, which is the engine D1 runs: a regeneration leaves recorded plays
alone, and a delete that would strand one is refused.
"""

import sqlite3
from pathlib import Path

from make_rounds import answers_sql

SCHEMA = "\n".join(
    f.read_text() for f in sorted((Path(__file__).parent / "migrations").glob("*.sql"))
)

IMAGE = "clips/clip_001-020000.mp4"


def db() -> sqlite3.Connection:
    conn = sqlite3.connect(":memory:")
    # D1 enforces foreign keys on every query and offers no way to turn them
    # off, so a test that left them at sqlite3's default (off) would assert
    # nothing about production.
    conn.execute("PRAGMA foreign_keys = ON")
    conn.executescript(SCHEMA)
    return conn


def answer(lat: float, lng: float, state: str = "CA") -> list[dict]:
    return [
        {"image": IMAGE, "lat": lat, "lng": lng, "state": state, "filmed": "2018-03-20"}
    ]


def record_a_play(conn: sqlite3.Connection) -> None:
    conn.execute(
        "INSERT INTO plays (date, player_id, image, km, points, played_at) "
        "VALUES ('2026-09-01', 'p1', ?, 12.5, 4120, '2026-09-01T10:00:00')",
        (IMAGE,),
    )


def test_a_regeneration_updates_the_row_rather_than_replacing_it():
    conn = db()
    conn.executescript(answers_sql(answer(34.0, -118.0)))
    record_a_play(conn)
    # The same image, re-scored: what a regeneration does to a round it keeps.
    # The play has to still be there afterwards, whatever ON DELETE action the
    # constraint grows later.
    conn.executescript(answers_sql(answer(35.5, -119.5, state="NV")))
    assert conn.execute(
        "SELECT lat, lng, state FROM answers WHERE image = ?", (IMAGE,)
    ).fetchone() == (35.5, -119.5, "NV")
    assert conn.execute("SELECT COUNT(*) FROM plays").fetchone()[0] == 1


def test_a_regeneration_leaves_rows_it_no_longer_covers():
    # Old rows for retired frames are kept on purpose: the schedule decides what
    # is playable, and a round already played still needs its answer to reveal.
    conn = db()
    conn.executescript(answers_sql(answer(34.0, -118.0)))
    other = [
        {
            "image": "clips/clip_002-030000.mp4",
            "lat": 40.0,
            "lng": -74.0,
            "state": "NY",
            "filmed": "2018-04-01",
        }
    ]
    conn.executescript(answers_sql(other))
    assert conn.execute("SELECT COUNT(*) FROM answers").fetchone()[0] == 2


def test_an_answer_a_play_depends_on_cannot_be_deleted():
    conn = db()
    conn.executescript(answers_sql(answer(34.0, -118.0)))
    record_a_play(conn)
    # The whole point of the constraint: this is the tidy-up that would have
    # broken the recap and share screens for rounds already played.
    try:
        conn.execute("DELETE FROM answers WHERE image = ?", (IMAGE,))
    except sqlite3.IntegrityError:
        pass
    else:
        raise AssertionError("delete of a referenced answer was allowed")
    assert conn.execute("SELECT COUNT(*) FROM plays").fetchone()[0] == 1


def test_an_unreferenced_answer_is_still_free_to_delete():
    conn = db()
    conn.executescript(answers_sql(answer(34.0, -118.0)))
    conn.execute("DELETE FROM answers WHERE image = ?", (IMAGE,))
    assert conn.execute("SELECT COUNT(*) FROM answers").fetchone()[0] == 0


def test_a_play_cannot_be_recorded_without_its_answer():
    conn = db()
    try:
        record_a_play(conn)
    except sqlite3.IntegrityError:
        return
    raise AssertionError("play recorded against an image with no answer row")


if __name__ == "__main__":
    for name, fn in sorted(globals().items()):
        if name.startswith("test_"):
            fn()
            print(f"ok {name}")
