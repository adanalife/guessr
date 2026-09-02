#!/usr/bin/env python3
"""Fill staging's schedule from production's, so a preview deploy is playable.

Staging's schedule backs every PR's preview deploy: smoke.sh fails a deployment
that serves no game today, so a lapsed staging schedule turns every open PR red
for a reason outside its own diff. That is what happened on 2026-09-02 -- eleven
days past staging's last scheduled date, four PRs red, none of them at fault.

Copying rather than generating, because the clips bucket is shared. A clip is
the same bytes whichever tier serves it (BUCKET in Taskfile.yml), so only the
rows are per-tier, and the rows are already sitting in production's database.
That makes this a seconds-long D1-to-D1 copy needing no corpus, no ffmpeg and no
scoring pass -- the things that make a real generation a 25-minute job that only
runs somewhere with the NFS mount.

It acts only when staging is actually short, which is what keeps it clear of a
set under review: `task rounds:publish` puts one there, and a mirror that ran
regardless would replace it. Short means what verify_days.sh means by it, read
through the same schedule_gaps.sql.

When it does act it replaces staging's whole upcoming schedule rather than
filling the holes. round_days is UNIQUE on image, so an incoming round already
scheduled on staging under a different date is silently dropped -- and filling
around that leaves a four-round day, which is the failure verify_days.sh exists
to catch. Replacing is the only version with one outcome. Safe because every
date it touches is unopened: an opened date's schedule is frozen (see
functions/admin/day.js), and staging has no players whose history it could be.
"""

from __future__ import annotations

import json
import pathlib
import subprocess
import sys

PROD = "adanalife-guessr-answers"
STAGE = "adanalife-guessr-answers-staging"
PER_GAME = 5  # ROUNDS_PER_GAME in check.py and web/index.html
HERE = pathlib.Path(__file__).parent

# The columns to carry over, verbatim. `status` is excluded and set below
# instead: it is a fact about the tier's own schedule, not about the clip.
# `batch` is included -- it names the generation run a round came from, which is
# the thread a bad batch is found again by, and a mirrored row that renamed it
# would break that on the tier where somebody is looking at the set.
ROUND_COLS = (
    "image",
    "median_km",
    "mean_cos",
    "batch",
    "slug",
    "source_ts_sec",
    "clip_ts_sec",
    "radius_m",
)
ANSWER_COLS = ("image", "lat", "lng", "state", "filmed")

# Production's upcoming schedule, joined to everything a round needs to play.
# An INNER JOIN on answers deliberately: a round with no answer row cannot be
# scored, so carrying one over would schedule a date that 500s on the first
# guess rather than failing here.
UPCOMING = f"""
SELECT rd.date AS date, rd.position AS position,
       {", ".join("r." + c + " AS " + c for c in ROUND_COLS)},
       {", ".join("a." + c + " AS a_" + c for c in ANSWER_COLS if c != "image")}
  FROM round_days rd
  JOIN rounds r ON r.image = rd.image
  JOIN answers a ON a.image = rd.image
 WHERE rd.date >= date('now')
 ORDER BY rd.date, rd.position
"""


def d1(db: str, command: str) -> list[dict]:
    """Run one read against a remote D1 and hand back its rows.

    `--command=` as one argument rather than two, because these queries lead
    with a `--` comment and wrangler's parser reads a separate value starting
    that way as more flags ("Unknown argument: Every date in a tier's
    horizon..."). verify_days.sh passes it the same way.
    """
    out = subprocess.run(
        [
            "npx",
            "wrangler",
            "d1",
            "execute",
            db,
            "--remote",
            "--json",
            f"--command={command}",
        ],
        capture_output=True,
        text=True,
        check=True,
        cwd=HERE,
    )
    return json.loads(out.stdout)[0]["results"]


def lit(value) -> str:
    """One SQL literal.

    ponytail: the same escape make_rounds.py's rounds_sql does, rather than an
    import of it -- that module is the scoring pipeline, and this runs on a CI
    runner with none of what the pipeline needs. A slug with an apostrophe is
    the case that makes it matter (test_schedule.py pins the same one).
    """
    if value is None:
        return "NULL"
    if isinstance(value, (int, float)):
        return repr(value)
    return "'" + str(value).replace("'", "''") + "'"


def rows_sql(
    table: str, cols: tuple[str, ...], rows: list[dict], prefix: str = ""
) -> str:
    """INSERT OR IGNORE for one table, or "" when there is nothing to insert.

    OR IGNORE because an `image` names one clip cut at one moment: a row already
    present is the same round rather than a stale version of it, so there is
    nothing an update could correct.
    """
    if not rows:
        return ""
    values = ",\n".join(
        "  ("
        + ", ".join(lit(r[prefix + c] if c != "image" else r["image"]) for c in cols)
        + ")"
        for r in rows
    )
    return f"INSERT OR IGNORE INTO {table} ({', '.join(cols)})\nVALUES\n{values};\n\n"


def mirror_sql(rows: list[dict]) -> str:
    """The whole copy, as one script: pool, answers, schedule, statuses.

    Ordered so it is applyable as written -- round_days.image references
    rounds(image), so the pool has to land first.
    """
    if not rows:
        return ""

    # De-duplicated: one clip plays on one date, but a round already in the pool
    # would otherwise be offered once per date it appears on.
    pool = list({r["image"]: r for r in rows}.values())
    booked = ",\n".join(
        f"  ({lit(r['date'])}, {r['position']}, {lit(r['image'])})" for r in rows
    )

    return (
        rows_sql("rounds", ROUND_COLS, pool)
        + rows_sql("answers", ANSWER_COLS, pool, prefix="a_")
        # Every unopened date goes, not just the ones being replaced. A date
        # staging holds and production does not is a leftover of an older set,
        # and leaving it would serve content no tier is reviewing.
        + "DELETE FROM round_days WHERE date >= date('now');\n\n"
        + f"INSERT OR IGNORE INTO round_days (date, position, image) VALUES\n{booked};\n\n"
        # Both directions, because the DELETE above unscheduled whatever staging
        # held: 'scheduled' has to stop being true for those. A rejected round
        # stays rejected -- that is a verdict, and re-queueing it would offer it
        # back to the next generation.
        "UPDATE rounds SET status = 'queued'\n"
        " WHERE status = 'scheduled'\n"
        "   AND image NOT IN (SELECT image FROM round_days);\n\n"
        "UPDATE rounds SET status = 'scheduled'\n"
        " WHERE status = 'queued' AND image IN (SELECT image FROM round_days);\n"
    )


def short_dates(db: str) -> list[str]:
    """The upcoming dates this tier cannot play, per schedule_gaps.sql."""
    gaps = d1(db, (HERE / "schedule_gaps.sql").read_text())
    return [r["date"] for r in gaps if r["n"] < PER_GAME]


def main(argv: list[str]) -> int:
    dry_run = "--dry-run" in argv

    short = short_dates(STAGE)
    if not short:
        print("staging is playable through its horizon -- nothing to mirror.")
        return 0
    print(f"staging is short on {len(short)} date(s): {', '.join(short)}")

    rows = d1(PROD, UPCOMING)
    if not rows:
        print(
            "::error::production has no upcoming schedule either, so there is "
            "nothing to mirror. Top production up first (`task rounds:topup`).",
            file=sys.stderr,
        )
        return 1

    dates = sorted({r["date"] for r in rows})
    print(
        f"mirroring {len(rows)} rounds over {len(dates)} dates ({dates[0]}..{dates[-1]})"
    )

    if dry_run:
        print("\n-- --dry-run: the script that would be applied to staging --\n")
        print(mirror_sql(rows))
        return 0

    sql = HERE / "mirror.sql"
    sql.write_text(mirror_sql(rows))
    try:
        subprocess.run(
            [
                "npx",
                "wrangler",
                "d1",
                "execute",
                STAGE,
                "--remote",
                f"--file={sql}",
                "--yes",
            ],
            check=True,
            cwd=HERE,
        )
    finally:
        sql.unlink(missing_ok=True)

    # The copy is only as good as what landed, and the same check every other
    # write path here ends with. A date production could not fill is still short
    # on staging, and this is what says so.
    return subprocess.run(
        [str(HERE / "verify_days.sh"), STAGE, "staging"], cwd=HERE
    ).returncode


if __name__ == "__main__":
    sys.exit(main(sys.argv[1:]))
