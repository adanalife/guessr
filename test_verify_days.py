"""schedule_gaps.sql reports the dates holding nothing, not just the short ones.

The query is what verify_days.sh asks a live D1, and the bug it exists to
prevent is a schedule that has run out reading as healthy. That is a fact about
the SQL, so the SQL is what these run -- against stdlib sqlite3, which is the
same engine D1 is built on.

Offsets are counted from the oldest still-open date, which is what the query
seeds its horizon with, so both sides derive their dates from the game's
closing rule instead of from a midnight. Reading them off two different
midnights is what made this fail locally every evening: the query truncated
UTC and the expectations truncated local time, and from 20:00 EDT until
midnight the two named different days. CI runs in UTC, so it never saw it.
"""

import datetime as dt
import pathlib
import re
import sqlite3

QUERY = (pathlib.Path(__file__).parent / "schedule_gaps.sql").read_text()
PER_GAME = 5  # ROUNDS_PER_GAME in check.py and web/index.html


SEED = re.search(r"SELECT (date\('now'[^)]*\))", QUERY).group(1)
CLOSES_UTC_HOUR = 12  # CLOSES_UTC_HOUR in web/daily.js


def seed_at(now):
    """The date the query's horizon seed resolves to at `now`, per sqlite."""
    expr = SEED.replace("'now'", "?")
    db = sqlite3.connect(":memory:")
    return db.execute(f"SELECT {expr}", (now.isoformat(sep=" "),)).fetchone()[0]


def oldest_open_at(now):
    """The oldest date still open at `now`, straight from the closing rule.

    Date D closes at D+1 CLOSES_UTC_HOUR:00 UTC, so it is open while `now` is
    before that. Found by walking back rather than by arithmetic, so it agrees
    with the seed expression only if the seed is actually right.
    """
    d = now.date() + dt.timedelta(days=1)
    while True:
        closes = dt.datetime.combine(
            d + dt.timedelta(days=1), dt.time(CLOSES_UTC_HOUR), dt.timezone.utc
        )
        if now >= closes:
            return (d + dt.timedelta(days=1)).isoformat()
        d -= dt.timedelta(days=1)


def counts(scheduled):
    """Run the query over a table holding `scheduled` -- {date: n_rounds}."""
    db = sqlite3.connect(":memory:")
    db.execute("CREATE TABLE round_days (date TEXT, image TEXT)")
    db.executemany(
        "INSERT INTO round_days (date, image) VALUES (?, ?)",
        [(day, f"{day}-{i}") for day, n in scheduled.items() for i in range(n)],
    )
    return {row[0]: row[1] for row in db.execute(QUERY)}


def oldest_open():
    """The first date schedule_gaps.sql enumerates.

    Date D is playable until D+1 12:00 UTC (playWindow in web/daily.js), so the
    oldest date not yet closed is 12 hours back in UTC -- the same instant the
    query seeds from, derived here independently of it.
    """
    return (dt.datetime.now(dt.timezone.utc) - dt.timedelta(hours=12)).date()


def day(offset):
    """A date `offset` days from the oldest still-open one. day(-1) is closed."""
    return (oldest_open() + dt.timedelta(days=offset)).isoformat()


def short(scheduled):
    return sorted(d for d, n in counts(scheduled).items() if n < PER_GAME)


def main():
    # The staging failure: fully scheduled, but only up to the last closed date.
    # The oldest open date has no rows, so grouping the table alone returns
    # nothing at all and reads as healthy -- it has to come back as a zero.
    assert short({day(-2): 5, day(-1): 5}) == [day(0)]
    assert short({}) == [day(0)]

    # A date with nothing, surrounded by full ones -- invisible to a GROUP BY
    # over the table, and it silently serves no game when it opens.
    assert short({day(0): 5, day(2): 5}) == [day(1)]

    # The collision case this check was originally written for.
    assert short({day(0): 5, day(1): 4, day(2): 5}) == [day(1)]

    assert short({day(0): 5, day(1): 5, day(2): 5}) == []

    # A closed date cannot be fixed, so a short one must not keep this red.
    assert short({day(-3): 2, day(0): 5}) == []

    # The horizon starts at the oldest *open* date, not at a midnight. Through
    # the Americas evening those differ, and the date being played is the one
    # the old seed dropped: a short game on it went unreported for four hours a
    # night. It is the first row whatever the hour, and the date before it --
    # closed -- is still absent even when it is the short one.
    assert min(counts({day(0): 5, day(1): 5})) == day(0)
    assert short({day(-1): 1, day(0): 5, day(1): 5}) == []

    # Dates beyond the horizon are unscheduled, not missing -- reporting them
    # would make every tier permanently short.
    assert sorted(counts({day(0): 5, day(1): 5})) == [day(0), day(1)]

    print("ok: an exhausted or empty schedule is short today, not silently clean")
    print("ok: a gap inside the horizon is reported")
    print("ok: a short day is reported, a full horizon is not")
    print("ok: closed dates and dates beyond the horizon are ignored")
    print("ok: the horizon starts at the oldest open date, not at a midnight")

    # Every hour of the day, not just the one the suite happens to run in. The
    # seed and the closing rule agreeing at 15:00 UTC says nothing about 01:00,
    # which is where they diverged -- and CI runs in UTC, so a local-midnight
    # seed passed here every time while failing on the laptop each evening.
    # Across a month, so a month boundary is covered too.
    start = dt.datetime(2026, 8, 20, tzinfo=dt.timezone.utc)
    for h in range(31 * 24):
        now = start + dt.timedelta(hours=h)
        assert seed_at(now) == oldest_open_at(now), now.isoformat()

    print(f"ok: seed matches the closing rule at all {31 * 24} hours tested")


if __name__ == "__main__":
    main()
