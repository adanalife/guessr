"""publish.sh --top-up refuses over a hole only on a date it could still fill.

The hole check reads schedule_gaps.sql, whose horizon starts at the oldest open
date -- yesterday until 12:00 UTC, while the top-up cron runs at 06:00. An open
date is frozen, so refusing over one stopped the top-up and let the horizon
drain. These run the two pieces publish.sh holds inline: the first-unopened
expression, against sqlite (D1's engine), and the jq filter, against jq.
"""

import datetime as dt
import json
import pathlib
import re
import sqlite3
import subprocess

from server import rules

SCRIPT = (pathlib.Path(__file__).parent / "publish.sh").read_text()
UNOPENED = re.search(r"(date\('now', '[^']*'\)) AS unopened", SCRIPT).group(1)
FILTER = re.search(r"--arg from \"\$unopened\" \\\n\s*'([^']*)'", SCRIPT).group(1)


def unopened_at(now):
    expr = UNOPENED.replace("'now'", "?")
    db = sqlite3.connect(":memory:")
    return db.execute(f"SELECT {expr}", (now.isoformat(sep=" "),)).fetchone()[0]


def hole(rows, unopened):
    """What publish.sh's jq makes of schedule_gaps.sql's rows."""
    out = subprocess.run(
        ["jq", "-r", "--arg", "from", unopened, FILTER],
        input=json.dumps([{"results": rows}]),
        capture_output=True,
        text=True,
        check=True,
    )
    return out.stdout.strip()


def main():
    # The expression is the server's opening rule at every hour of a month,
    # across a month boundary: the date it names has not opened, and the one
    # before it has.
    start = dt.datetime(2026, 8, 20, tzinfo=dt.UTC)
    for h in range(31 * 24):
        now = start + dt.timedelta(hours=h)
        first = unopened_at(now)
        assert rules.play_window(first)[0] > now, now.isoformat()
        before = (dt.date.fromisoformat(first) - dt.timedelta(days=1)).isoformat()
        assert rules.play_window(before)[0] <= now, now.isoformat()
    print(f"ok: the first unopened date matches the opening rule at {31 * 24} hours")

    # Monday 06:00 UTC: 10-19 is still open (until 12:00), 10-20 is open, 10-21
    # opens at 10:00.
    first = unopened_at(dt.datetime(2026, 10, 20, 6, tzinfo=dt.UTC))
    assert first == "2026-10-21"
    full = [{"date": f"2026-10-{d}", "n": 5} for d in (20, 21, 22)]
    # A short date that is still open is past filling, and no reason to refuse.
    assert hole([{"date": "2026-10-19", "n": 3}, *full], first) == ""
    # A hole on a date nobody has opened is still refused.
    holed = [{"date": "2026-10-19", "n": 5}, {"date": "2026-10-21", "n": 4}]
    assert hole(holed, first) == "2026-10-21 has 4 of 5"
    assert hole(full, first) == ""
    print("ok: an open short date is ignored, an unopened one still refuses")


if __name__ == "__main__":
    main()
