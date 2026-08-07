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
set -euo pipefail

cd "$(dirname "$0")"

DB="${1:?which D1 database}"
TIER="${2:-$DB}"
PER_GAME=5 # ROUNDS_PER_GAME in check.py and web/index.html

short=$(npx wrangler d1 execute "$DB" --remote --json \
  --command="SELECT date, COUNT(*) AS n FROM round_days WHERE date >= date('now') GROUP BY date HAVING n < $PER_GAME ORDER BY date" |
  jq -r '.[0].results[] | "  \(.date) has \(.n) of '"$PER_GAME"'"')

if [ -n "$short" ]; then
  # ::error:: so a CI run surfaces it as an annotation; the exit is what stops a
  # cron from treating a short schedule as a good night's work.
  echo "::error::$TIER has dates scheduled with fewer than $PER_GAME rounds" >&2
  echo "$short" >&2
  echo "fill them from the queue before the earliest one opens." >&2
  exit 1
fi

echo "schedule ok: every upcoming $TIER date has $PER_GAME rounds"
