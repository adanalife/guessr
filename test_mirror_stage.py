"""mirror_stage's copy applies cleanly and leaves staging playable.

The SQL is the whole of this script's risk -- it deletes a schedule and rewrites
it -- so the test applies it for real, against a database built from the actual
migrations, and asserts on what came out. sqlite3 is D1's own engine, so the
unique index and the foreign key behave here as they do there.
"""

import datetime as dt
import pathlib
import sqlite3

from mirror_stage import PER_GAME, lit, mirror_sql

HERE = pathlib.Path(__file__).parent


def fresh():
    """A database with the real schema, migrations applied in filename order."""
    db = sqlite3.connect(":memory:")
    db.execute("PRAGMA foreign_keys = ON")
    for m in sorted((HERE / "migrations").glob("*.sql")):
        db.executescript(m.read_text())
    return db


def day(offset):
    """A date relative to today. The copy's DELETE is scoped by date('now'), so
    a fixture on a fixed date would pass until that date went past and then fail
    for a reason having nothing to do with the code."""
    return (dt.date.today() + dt.timedelta(days=offset)).isoformat()


def prod_rows(dates, slug="i-80-eastbound", start=0):
    """What UPCOMING returns: one row per scheduled round, joined to its answer."""
    rows = []
    n = start
    for date in dates:
        for position in range(1, PER_GAME + 1):
            n += 1
            rows.append(
                {
                    "date": date,
                    "position": position,
                    "image": f"clips/{slug}-{n:06d}.mp4",
                    "median_km": 1.5,
                    "mean_cos": 0.2,
                    "batch": "20260902T060000Z",
                    "slug": slug,
                    "source_ts_sec": float(n),
                    "clip_ts_sec": float(n),
                    "radius_m": 40.0,
                    "a_lat": 41.0 + n / 1000,
                    "a_lng": -95.0 - n / 1000,
                    "a_state": "NE",
                    "a_filmed": "2026-05-01",
                }
            )
    return rows


def schedule(db):
    return {
        date: n
        for date, n in db.execute("SELECT date, COUNT(*) FROM round_days GROUP BY date")
    }


def apply(db, rows):
    db.executescript(mirror_sql(rows))
    return db


def main():
    # Order: round_days references rounds(image), so a script that inserted the
    # schedule first would fail here with foreign keys on.
    rows = prod_rows([day(1), day(2)])
    db = apply(fresh(), rows)
    assert schedule(db) == {day(1): PER_GAME, day(2): PER_GAME}
    assert db.execute("SELECT COUNT(*) FROM answers").fetchone()[0] == len(rows)
    # Every mirrored round is scheduled, and nothing else claims to be.
    assert db.execute(
        "SELECT COUNT(*) FROM rounds WHERE status = 'scheduled'"
    ).fetchone()[0] == len(rows)

    # Re-running changes nothing: the copy has to be safe on a daily cron.
    before = schedule(db)
    apply(db, rows)
    assert schedule(db) == before
    assert db.execute("SELECT COUNT(*) FROM rounds").fetchone()[0] == len(rows)

    # A round staging holds on a *different* upcoming date is the case OR IGNORE
    # alone would turn into a short day: round_days is UNIQUE on image, so the
    # incoming row would be dropped and the date left with four. The DELETE is
    # what makes it land.
    db = fresh()
    stale = prod_rows([day(1)])
    db.executescript(mirror_sql(stale))
    moved = [dict(r, date=day(3)) for r in stale]
    db.executescript(mirror_sql(moved))
    assert schedule(db) == {day(3): PER_GAME}

    # A date staging holds and production does not is an older set's leftover,
    # and goes with the rest of the upcoming schedule.
    db = fresh()
    db.executescript(mirror_sql(prod_rows([day(1), day(7)])))
    db.executescript(mirror_sql(prod_rows([day(1)], slug="us-30", start=500)))
    assert schedule(db) == {day(1): PER_GAME}
    # The rounds it unscheduled are queued again, not left claiming a slot.
    assert (
        db.execute("SELECT COUNT(*) FROM rounds WHERE status = 'scheduled'").fetchone()[
            0
        ]
        == PER_GAME
    )

    # A rejection is a verdict, not a scheduling state: re-queueing one would
    # offer the clip back to the next generation run.
    db = fresh()
    db.executescript(mirror_sql(prod_rows([day(1)])))
    dud = db.execute("SELECT image FROM round_days").fetchone()[0]
    db.execute("UPDATE rounds SET status = 'rejected' WHERE image = ?", (dud,))
    db.executescript(mirror_sql(prod_rows([day(2)], slug="us-30", start=900)))
    assert (
        db.execute("SELECT status FROM rounds WHERE image = ?", (dud,)).fetchone()[0]
        == "rejected"
    )

    # A slug with an apostrophe is escaped rather than ending the string. The
    # corpus has none today, which is why it would otherwise be found by a cron
    # dying at 3am.
    db = fresh()
    odd = prod_rows([day(1)], slug="o'brien")
    db.executescript(mirror_sql(odd))
    assert db.execute("SELECT slug FROM rounds LIMIT 1").fetchone()[0] == "o'brien"
    assert schedule(db) == {day(1): PER_GAME}

    # Nothing upcoming on production is not an empty script that would delete
    # staging's schedule and put nothing back.
    assert mirror_sql([]) == ""

    assert lit(None) == "NULL"
    assert lit("it's") == "'it''s'"

    print("ok: the copy applies in dependency order and leaves whole days")
    print("ok: re-running is a no-op, and a moved or leftover date converges")
    print("ok: a rejection survives the copy, and a quoted slug is escaped")
    print("ok: an empty production schedule generates no script at all")


if __name__ == "__main__":
    main()
