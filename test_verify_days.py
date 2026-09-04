"""schedule_gaps.sql reports the dates holding nothing, not just the short ones.

The query is what verify_days.sh asks a live D1, and the bug it exists to
prevent is a schedule that has run out reading as healthy. That is a fact about
the SQL, so the SQL is what these run -- against stdlib sqlite3, which is the
same engine D1 is built on.
"""

import datetime as dt
import pathlib
import sqlite3

QUERY = (pathlib.Path(__file__).parent / "schedule_gaps.sql").read_text()
PER_GAME = 5  # ROUNDS_PER_GAME in check.py and web/index.html


def counts(scheduled):
    """Run the query over a table holding `scheduled` -- {date: n_rounds}."""
    db = sqlite3.connect(":memory:")
    db.execute("CREATE TABLE round_days (date TEXT, image TEXT)")
    db.executemany(
        "INSERT INTO round_days (date, image) VALUES (?, ?)",
        [(day, f"{day}-{i}") for day, n in scheduled.items() for i in range(n)],
    )
    return {row[0]: row[1] for row in db.execute(QUERY)}


def day(offset):
    return (dt.date.today() + dt.timedelta(days=offset)).isoformat()


def short(scheduled):
    return sorted(d for d, n in counts(scheduled).items() if n < PER_GAME)


def main():
    # The staging failure: fully scheduled, but only up to yesterday. Today has
    # no rows, so grouping the table alone returns nothing at all and reads as
    # healthy -- today has to come back as a zero.
    assert short({day(-2): 5, day(-1): 5}) == [day(0)]
    assert short({}) == [day(0)]

    # A date with nothing, surrounded by full ones -- invisible to a GROUP BY
    # over the table, and it silently serves no game when it opens.
    assert short({day(0): 5, day(2): 5}) == [day(1)]

    # The collision case this check was originally written for.
    assert short({day(0): 5, day(1): 4, day(2): 5}) == [day(1)]

    assert short({day(0): 5, day(1): 5, day(2): 5}) == []

    # A played date cannot be fixed, so a short one must not keep this red.
    assert short({day(-3): 2, day(0): 5}) == []

    # Dates beyond the horizon are unscheduled, not missing -- reporting them
    # would make every tier permanently short.
    assert sorted(counts({day(0): 5, day(1): 5})) == [day(0), day(1)]

    print("ok: an exhausted or empty schedule is short today, not silently clean")
    print("ok: a gap inside the horizon is reported")
    print("ok: a short day is reported, a full horizon is not")
    print("ok: past dates and dates beyond the horizon are ignored")


if __name__ == "__main__":
    main()
