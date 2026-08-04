#!/usr/bin/env python3
"""Write a round set that needs no corpus, for the local integration run.

`make_rounds.py` needs the dashcam corpus on a mount and a Postgres full of
embeddings, neither of which CI has. What the endpoints actually need is far
less: rows in `rounds`, `round_days` and `answers`. So this fabricates the
scored candidates and hands them to the *real* `rounds_sql` / `answers_sql` /
`schedule`.

That last part is the point. A fixture that hand-wrote its own INSERTs would
drift from the generator the first time a column moved, and drift silently --
the integration run would keep passing against a shape nothing produces any
more. Going through the same functions means a change to the generated SQL
either works here too or breaks this immediately.

Scheduled from **two days before today**, not from the generator's usual two
days *ahead*: the run has to ask for a date that is open right now, and the
generator deliberately never schedules one of those.
"""

import argparse
import datetime as dt
from pathlib import Path

from make_rounds import ROUNDS_PER_GAME, answers_sql, rounds_sql, schedule

HERE = Path(__file__).parent


def build(days: int) -> tuple[list[dict], list[dict]]:
    """`days` days of rounds, spread over the country so nothing clusters."""
    rounds, answers = [], []
    for i in range(days * ROUNDS_PER_GAME):
        slug = f"2018_0101_{i:06d}_000_opt"
        image = f"clips/{slug}-{(i + 1) * 1000:06d}.mp4"
        rounds.append(
            {
                "image": image,
                # Scattered rather than sequential, so a day's five span the
                # difficulty range and the ramp has something to order.
                "median_km": float((i * 37) % 250),
                "mean_cos": 0.07,
            }
        )
        answers.append(
            {
                "image": image,
                # Inside check.py's continental bounds, walked across the map so
                # no two rounds share an answer.
                "lat": 32.0 + (i % 15) * 1.1,
                "lng": -120.0 + (i % 50) * 1.05,
                "state": "CA",
                "filmed": "2018-01-01",
                "slug": slug,
                "source_ts_sec": float(i + 20),
                "clip_ts_sec": float(i + 20),
                "radius_m": 60.0,
            }
        )
    return rounds, answers


def main() -> int:
    ap = argparse.ArgumentParser(description=__doc__)
    ap.add_argument("--days", type=int, default=5)
    ap.add_argument("--dest", type=Path, default=HERE)
    args = ap.parse_args()

    rounds, answers = build(args.days)
    first = dt.datetime.now(dt.timezone.utc).date() - dt.timedelta(days=2)
    days = schedule(rounds, first, args.days)

    (args.dest / "rounds.sql").write_text(rounds_sql(rounds, answers, "fixture", days))
    (args.dest / "answers.sql").write_text(answers_sql(answers))
    print(
        f"fixture: {len(rounds)} rounds over {args.days} days, "
        f"{first} to {max(d for d, _, _ in days)}"
    )
    return 0


if __name__ == "__main__":
    raise SystemExit(main())
