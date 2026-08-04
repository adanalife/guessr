#!/usr/bin/env python3
"""Cover how a generated pool becomes a schedule, and the SQL that lands it.

This is where the daily draw went. It used to be a seeded shuffle in daily.js
that the page and the scorer both re-ran, and test_daily.mjs pinned it; now a
date's five are chosen once, here, and written to `round_days`. The properties
that mattered then still matter, they are just properties of this function:

- a date's five come out in ramp order, because nothing downstream sorts them;
- no round is ever scheduled twice, which is what stops a daily player meeting
  the same footage again;
- a day is a spread of difficulties rather than a block of the pool.

The last is the one worth a test rather than a glance. Dealing rounds in blocks
of five would satisfy every other assertion here and produce a month that gets
steadily harder instead of a game that does -- a failure nobody would see until
week three, and never as an error.

The SQL half runs against the real schema.sql over stdlib sqlite3, which is D1's
own engine: a generated script that will not load is a publish that dies after
25 minutes of encoding, and this is the cheapest place to find out.
"""

import sqlite3
import tempfile
from datetime import date, timedelta
from pathlib import Path

from make_rounds import ROUNDS_PER_GAME, rounds_sql, schedule

SCHEMA = (Path(__file__).parent / "schema.sql").read_text()
START = date(2026, 9, 1)


def pool(n: int) -> list[dict]:
    """A pool whose difficulty order is deliberately not its list order.

    (i * 37) % 250 scatters median_km, so a schedule that happens to preserve
    insertion order comes out unramped and is caught.
    """
    return [
        {
            "image": f"clips/clip_{i:03d}-{(i + 1) * 1000:06d}.mp4",
            "median_km": float((i * 37) % 250),
            "mean_cos": 0.07,
        }
        for i in range(n)
    ]


def answers_for(rounds: list[dict]) -> list[dict]:
    return [
        {
            "image": r["image"],
            "slug": r["image"].removeprefix("clips/").rsplit("-", 1)[0],
            "source_ts_sec": 20.0,
            "clip_ts_sec": 20.0,
            "radius_m": 60.0,
        }
        for r in rounds
    ]


def by_date(days: list[tuple]) -> dict[str, list[dict]]:
    out: dict[str, list[dict]] = {}
    for d, position, r in sorted(days, key=lambda x: (x[0], x[1])):
        out.setdefault(d, []).append(r)
    return out


def main() -> None:
    rounds = pool(100)
    days = schedule(rounds, START, 60)

    # 100 rounds fills 20 days, not 60: a partial day is not scheduled at all,
    # because a game that is three rounds long is worse than one fewer day.
    assert len({d for d, _, _ in days}) == 20, days
    assert len(days) == 100

    games = by_date(days)

    # Consecutive dates from the one asked for, with no gaps -- a missing date in
    # the middle is a day the game is simply down.
    assert sorted(games) == [(START + timedelta(days=i)).isoformat() for i in range(20)]

    for d, game in games.items():
        assert len(game) == ROUNDS_PER_GAME, f"{d} is {len(game)} rounds"
        # Ramped, which is the whole of the order: /api/day returns them by
        # position and nothing sorts them after.
        got = [r["median_km"] for r in game]
        assert got == sorted(got), f"{d} is not ordered easy to hard: {got}"

    # THE ONE THAT MATTERS. Every day spans the difficulty range rather than
    # sitting in one part of it. Dealt in blocks, the first day's hardest round
    # would be easier than the last day's easiest; dealt round-robin, every day
    # reaches both ends. Checked as "no day is entirely inside one half of the
    # range", which blocks fail and a round-robin passes with room to spare.
    lo = min(r["median_km"] for r in rounds)
    hi = max(r["median_km"] for r in rounds)
    mid = (lo + hi) / 2
    for d, game in games.items():
        km = [r["median_km"] for r in game]
        assert min(km) < mid < max(km), f"{d} draws from one end only: {km}"

    # No round is scheduled twice. round_days_once enforces it in the database
    # too, but a generator that relied on the constraint would have its INSERT OR
    # IGNORE silently drop rounds and leave short days.
    images = [r["image"] for _, _, r in days]
    assert len(set(images)) == len(images), "a round was scheduled twice"

    # Order-independence: the schedule depends on which rounds exist and how hard
    # they are, never on the order make_rounds.py happened to emit them in.
    assert by_date(schedule(list(reversed(rounds)), START, 60)) == games

    # Deterministic. Two runs over the same pool must agree, or a re-push after a
    # failure writes a different game for a date already handed out.
    assert by_date(schedule(rounds, START, 60)) == games

    # The horizon is a ceiling, not a target: a pool bigger than it leaves the
    # surplus queued rather than scheduling past it.
    short = schedule(pool(100), START, 5)
    assert len({d for d, _, _ in short}) == 5
    assert len(short) == 25

    # Too few to fill a single day schedules nothing at all -- a four-round game
    # is not a game, and a partial one would be handed out as if it were whole.
    assert schedule(pool(ROUNDS_PER_GAME - 1), START, 60) == []
    assert schedule([], START, 60) == []
    assert len(schedule(pool(ROUNDS_PER_GAME), START, 60)) == ROUNDS_PER_GAME

    # And the SQL, against the real DDL.
    with tempfile.TemporaryDirectory() as tmp:
        db = sqlite3.connect(Path(tmp) / "t.db")
        db.executescript(SCHEMA)
        db.executescript(rounds_sql(rounds, answers_for(rounds), "batch-1", days))

        assert db.execute("SELECT count(*) FROM rounds").fetchone()[0] == 100
        assert db.execute("SELECT count(*) FROM round_days").fetchone()[0] == 100

        # Status follows the schedule rather than being asserted alongside it:
        # everything placed is scheduled, everything left over stays queued for a
        # later run to pick up.
        counts = dict(db.execute("SELECT status, count(*) FROM rounds GROUP BY status"))
        assert counts == {"scheduled": 100}, counts

        # A run that generates more than it can place leaves the remainder
        # queued, which is the state the next run's headroom comes from.
        db2 = sqlite3.connect(Path(tmp) / "t2.db")
        db2.executescript(SCHEMA)
        big = pool(60)
        db2.executescript(
            rounds_sql(big, answers_for(big), "batch-2", schedule(big, START, 5))
        )
        assert dict(
            db2.execute("SELECT status, count(*) FROM rounds GROUP BY status")
        ) == {"scheduled": 25, "queued": 35}

        # Re-running the same script changes nothing. publish.sh pushes this file
        # whole, and a retry after a half-finished push has to be safe.
        db.executescript(rounds_sql(rounds, answers_for(rounds), "batch-1", days))
        assert db.execute("SELECT count(*) FROM round_days").fetchone()[0] == 100

        # A reject survives a re-push, which is the reason the status UPDATE is
        # scoped to 'queued' rather than rewriting every scheduled row. Without
        # that, publishing again would quietly un-reject everything /admin threw
        # out.
        victim = images[0]
        db.execute("UPDATE rounds SET status = 'rejected' WHERE image = ?", (victim,))
        db.executescript(rounds_sql(rounds, answers_for(rounds), "batch-1", days))
        assert (
            db.execute(
                "SELECT status FROM rounds WHERE image = ?", (victim,)
            ).fetchone()[0]
            == "rejected"
        )

        # The provenance reaches the table, since a round that loses it cannot be
        # rebuilt from its source clip.
        slug, src, clip, radius = db.execute(
            "SELECT slug, source_ts_sec, clip_ts_sec, radius_m FROM rounds "
            "WHERE image = ?",
            (images[1],),
        ).fetchone()
        assert slug and src == 20.0 and clip == 20.0 and radius == 60.0

        # A quote in a slug is escaped rather than ending the string. Nothing in
        # the corpus has one today, which is exactly why it would be found by a
        # publish dying at 3am rather than by anybody looking.
        odd = [{"image": "clips/o'brien-001000.mp4", "median_km": 1.0, "mean_cos": 0.1}]
        db3 = sqlite3.connect(Path(tmp) / "t3.db")
        db3.executescript(SCHEMA)
        db3.executescript(rounds_sql(odd, answers_for(odd), "o'batch", []))
        assert (
            db3.execute("SELECT image FROM rounds").fetchone()[0]
            == "clips/o'brien-001000.mp4"
        )

    print("ok: a day is five rounds, ramped, spanning the difficulty range")
    print("ok: the schedule is deterministic and never places a round twice")
    print("ok: the generated SQL loads, is re-runnable, and keeps a reject")


if __name__ == "__main__":
    main()
