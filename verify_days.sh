#!/usr/bin/env bash
# Fail if any upcoming date is scheduled with fewer than a full game.
#
# `round_days_once` is a UNIQUE index on `image`, so a run that re-picks a moment
# the tier has already scheduled loses that row to the schedule's INSERT OR
# IGNORE. Nothing announces it: the push reports success, the pool is one round
# short, and the date is quietly a four-round game against a five-round
# leaderboard. Seen for real on staging 2026-08-07, pushing a --per-clip 12 set
# over dates a previous set had already used.
#
# check.py cannot catch it. It validates the set on the laptop, and the collision
# does not exist there -- it is a fact about the destination. test_schedule.py
# covers the half that is local (one generator run never schedules a round
# twice); this is the other half, and it is the only one that needs a database.
#
# Every path that writes a schedule calls this, not just publish.sh: a bare
# `task rounds:stage:push` is how the staging short day got there.
#
# Dates from today forward only. A past date has already been played and cannot
# be fixed, so counting it would leave this permanently red and therefore unread.
#
# A date holding no rounds at all counts here too, not just a short one --
# schedule_gaps.sql enumerates the horizon so an exhausted or gapped schedule
# has rows to be counted as zero. Staging sat eleven days past its last
# scheduled date without that (2026-09-02), green here the whole time, while
# every PR's preview deploy failed its smoke test for serving no game today.
set -euo pipefail

cd "$(dirname "$0")"

DB="${1:?which D1 database}"
TIER="${2:-$DB}"
PER_GAME=5 # ROUNDS_PER_GAME in check.py and web/index.html

# The query enumerates the whole horizon and counts it; the threshold is applied
# here, so PER_GAME stays in one place rather than interpolated into the SQL.
state=$(npx wrangler d1 execute "$DB" --remote --json \
  --command="$(cat schedule_gaps.sql)")
short=$(jq -r --argjson per "$PER_GAME" \
  '.[0].results[] | select(.n < $per) | "  \(.date) has \(.n) of \($per)"' <<<"$state")

if [ -n "$short" ]; then
  last=$(npx wrangler d1 execute "$DB" --remote --json \
    --command="SELECT MAX(date) AS last_day FROM round_days" |
    jq -r '.[0].results[0].last_day // "never"')

  # ::error:: so a CI run surfaces it as an annotation; the exit is what stops a
  # cron from treating a short schedule as a good night's work.
  echo "::error::$TIER has dates scheduled with fewer than $PER_GAME rounds" >&2
  echo "$short" >&2
  echo "$TIER's last scheduled date is $last." >&2
  # Which of the two it is decides the fix, and the counts above do not say:
  # a short day is filled from the queue, an exhausted horizon needs a set
  # generated over the missing dates.
  echo "fill a short day from the queue before it opens; if the horizon has run" >&2
  echo "out, generate a set whose schedule covers the dates listed above." >&2
  exit 1
fi

echo "schedule ok: every upcoming $TIER date has $PER_GAME rounds"
