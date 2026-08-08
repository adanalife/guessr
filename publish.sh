#!/usr/bin/env bash
# Generate a round set and publish it, in the one order that is safe. This is
# what a scheduled job runs; `task rounds:publish` is the same thing by hand.
#
# A round set reaches players as three things, and nothing here is a deploy:
#
#   1. the media, one R2 object per clip
#   2. the answers, rows in the answers table
#   3. the pool and the schedule, rows in `rounds` and `round_days`
#
# THE SCHEDULE LAST, always, because it is the only one of the three that makes a
# date playable. Get the order wrong and a player reaches a round whose clip is a
# black pane (no media) or whose every guess comes back `unknown round` (no
# answers) -- both were seen for real on 2026-08-02, pushing the first set by
# hand. Push it last and the worst case is a date that is not scheduled yet,
# which nobody can see.
#
# Two modes, one target each. Bare, this builds a full fresh set for STAGING --
# the development tier, whose schedule is disposable. With --top-up it targets
# PRODUCTION under the top-up contract: keep TOPUP_DAYS scheduled ahead, never
# schedule inside TOPUP_LEAD days, keep TOPUP_QUEUE rounds queued for
# reject-and-replace, and generate nothing when the horizon is already healthy.
# The lead time is the review window -- every round sits on the admin page,
# rejectable, for at least TOPUP_LEAD days before a player can meet it. Review
# is possible the whole time and required never; check.py below stays the gate
# that runs unconditionally.
#
# What used to be here and is not: git. This opened a pull request to commit
# web/rounds.json, because the round set was a deployed file and a deploy was the
# only way it could reach anyone. Rows in D1 need no branch, no token with write
# on a public repo's default branch, and no merge -- which deletes the one
# genuinely new trust surface running this on a schedule was going to introduce.
#
# The cost of that, stated plainly rather than discovered later: `pr-gates` used
# to run check.py over the committed manifest, and there is no longer a pull
# request for it to run on. check.py runs below instead, before anything is
# published -- earlier than the PR gate did, but on this machine's word alone.
#
# Needs, beyond what a laptop has: CLOUDFLARE_ACCOUNT_ID and an API token with R2
# write on the clips bucket and D1 write on the staging database.
set -euo pipefail

cd "$(dirname "$0")"

STAGE_DB="adanalife-guessr-answers-staging"
PROD_DB="adanalife-guessr-answers"

# The top-up contract's numbers, env-overridable because they are working
# values ([[prod-automation-design]] says revisit after a month of real runs):
# how far ahead production stays scheduled, how close to an open date a run may
# schedule (the floor of the review window), how deep the queued tail that
# reject-and-replace draws from must be, and how long after a clip airs before
# it may be dealt again. The replay window is what keeps the corpus indefinite:
# burning clips forever consumes ~1,800 a year at this cadence, while a rolling
# window caps the burned set at cadence x window and the pool stops shrinking.
TOPUP_DAYS="${TOPUP_DAYS:-14}"
TOPUP_LEAD="${TOPUP_LEAD:-3}"
TOPUP_QUEUE="${TOPUP_QUEUE:-10}"
TOPUP_REPLAY_DAYS="${TOPUP_REPLAY_DAYS:-180}"
# Interpolated into SQL below, so a non-number must die here rather than there.
: $((TOPUP_REPLAY_DAYS + 0))

MODE=stage
DB="$STAGE_DB"
TIER=staging
if [ "${1:-}" = "--top-up" ]; then
  shift
  MODE=topup
  DB="$PROD_DB"
  TIER=production
fi

# Both credentials up front, before the 25 minutes of encoding rather than after.
# Discovering a missing token at the first publish step means paying for the whole
# generation again, and this runs somewhere nobody is watching.
: "${CLOUDFLARE_ACCOUNT_ID:?needed by clips.sh and wrangler}"
: "${CLOUDFLARE_API_TOKEN:?needs R2 write on the clips bucket and D1 write}"

if [ "$MODE" = "topup" ]; then
  echo "== reading $TIER's horizon"
  state=$(npx wrangler d1 execute "$DB" --remote --json --command="SELECT (SELECT MAX(date) FROM round_days) AS last_day, (SELECT CAST(julianday(MAX(date)) - julianday(date('now')) AS INTEGER) FROM round_days) AS days_left, (SELECT COUNT(*) FROM rounds WHERE status = 'queued') AS queued")
  last_day=$(jq -r '.[0].results[0].last_day // empty' <<<"$state")
  days_left=$(jq -r '.[0].results[0].days_left // 0' <<<"$state")
  queued=$(jq -r '.[0].results[0].queued' <<<"$state")

  days_needed=$((TOPUP_DAYS - days_left))
  [ "$days_needed" -lt 0 ] && days_needed=0
  queue_needed=$((TOPUP_QUEUE - queued))
  [ "$queue_needed" -lt 0 ] && queue_needed=0
  count=$((days_needed * 5 + queue_needed))

  # The healthy exit, which is what makes the job idempotent, safe to re-run,
  # and cheap on the weeks nothing is missing.
  if [ "$count" -eq 0 ]; then
    echo "$TIER is healthy: $days_left days scheduled (want $TOPUP_DAYS), $queued queued (want $TOPUP_QUEUE). Nothing to generate."
    exit 0
  fi

  # check.py refuses a set shorter than one game, so a queue-only top-up still
  # generates five; the surplus stays queued, which is where it was headed.
  [ "$count" -lt 5 ] && count=5

  # New dates land after everything scheduled AND at least TOPUP_LEAD days out,
  # whichever is later. The second bound is the review window; the first means
  # a horizon that already reaches past the window just gets extended.
  from=$(python3 - "$last_day" "$TOPUP_LEAD" <<'PY'
import datetime as dt
import sys

last, lead = sys.argv[1], int(sys.argv[2])
after_last = dt.date.fromisoformat(last) + dt.timedelta(days=1) if last else dt.date.min
earliest = dt.datetime.now(dt.UTC).date() + dt.timedelta(days=lead)
print(max(after_last, earliest))
PY
)

  # What the tier holds is burned, but not all of it forever. Queued and
  # rejected are permanent -- a reject is a human judgement about the content,
  # and expiring it would resurrect the round through round_days pointing at
  # its kept row. An *aired* clip cools off instead: round_days is the log of
  # every airing, so a slug frees up once every round on it has aired and the
  # newest airing is older than the replay window. A round that never aired and
  # was never rejected stays burned too -- it is either scheduled ahead or an
  # anomaly, and neither is a thing to deal twice. See burned_slugs() in
  # make_rounds.py for why the unit is the whole clip.
  echo "== reading what $TIER already holds"
  {
    echo "# slugs $TIER holds (aired within ${TOPUP_REPLAY_DAYS}d, queued, or rejected), read $(date -u +%Y-%m-%dT%H:%MZ) -- written by publish.sh --top-up, not by hand"
    npx wrangler d1 execute "$DB" --remote --json --command="SELECT DISTINCT r.slug FROM rounds r WHERE r.status IN ('queued', 'rejected') OR NOT EXISTS (SELECT 1 FROM round_days d WHERE d.image = r.image) OR EXISTS (SELECT 1 FROM round_days d WHERE d.image = r.image AND d.date >= date('now', '-${TOPUP_REPLAY_DAYS} days'))" | jq -r '.[0].results[].slug'
  } >burned.txt

  echo "top-up: $days_needed days from $from plus $queue_needed for the queue = $count rounds ($TIER has $days_left days, $queued queued)"
  set -- -n "$count" --horizon "$days_needed" --schedule-from "$from" --exclude burned.txt "$@"
fi

echo "== generating"
# Everything after this is the published artifact, so a knob change belongs here
# rather than in the job spec that calls this.
python3 make_rounds.py "$@"

# THE guard. Nothing else stands between a generated set and the game: it catches
# a 16:9 frame (the HUD crop did not run, so the answer is printed on the image),
# a coordinate on the round side of the split, and a clip that encoded to an empty
# container. Before any publish step, so a bad set costs 25 minutes and nothing
# else.
#
# make_rounds.py already ran this against its staging directory and refused to
# swap a failing set in. Again here because this is the last point at which
# nothing has left the laptop -- and because a set can be published by a rerun of
# this script over a set generated earlier.
echo "== validating"
python3 check.py

echo "== 1/3 media to R2"
./clips.sh push

echo "== 2/3 answers to the $TIER D1"
npx wrangler d1 execute "$DB" --remote --file answers.sql --yes

# Last, and only now: the schedule, which is the thing that gives a date a game.
echo "== 3/3 pool and schedule to the $TIER D1"
npx wrangler d1 execute "$DB" --remote --file rounds.sql --yes

# What a reviewer needs, and what a Discord notification will carry: how much was
# generated, how far ahead the game is now covered, and what is left over. Read
# back out of the database rather than out of the local files, so it describes
# what actually landed.
#
# The queue is the half the horizon does not describe. A rejection on the admin
# page is paid for out of queued surplus, and with none it is paid for out of the
# schedule's tail instead -- the whole last day goes back to 'queued' to keep the
# horizon from ending on a partial game. So a tier can be scheduled a fortnight
# out and still be one bad clip away from losing a day of that, which the depth
# number alone reads as healthy. The top-up contract already keeps TOPUP_QUEUE
# rounds back for exactly this; the run that maintains it never said whether it
# had.
readback=$(npx wrangler d1 execute "$DB" --remote --json \
  --command="SELECT count(DISTINCT date) AS days, CAST(julianday(MAX(date)) - julianday(date('now')) AS INTEGER) AS ahead, max(date) AS through, (SELECT COUNT(*) FROM rounds WHERE status = 'queued') AS queued FROM round_days")
scheduled=$(jq -r '.[0].results[0] | "\(.days) days, \(.ahead) ahead, through \(.through), \(.queued) queued"' <<<"$readback")

echo "published to $TIER: $scheduled"

# Before the depth guard, and in both modes: depth asks whether the schedule
# reaches far enough, this asks whether the days inside it are whole. A run can
# pass the first and fail this one, which is exactly what a --per-clip 12 push
# to staging did on 2026-08-07.
./verify_days.sh "$DB" "$TIER"

if [ "$MODE" = "topup" ]; then
  # The depth guard, from the readback rather than this run's arithmetic, so it
  # catches everything upstream of it: a generation that quietly produced too
  # little, a schedule leg that did not land, a miscounted horizon. A thin
  # answer here fails the run, and the job failing IS the alert.
  days_after=$(jq -r '.[0].results[0].ahead' <<<"$readback")
  if [ "$days_after" -lt 7 ]; then
    echo "::error::$TIER is scheduled only $days_after days out after a top-up -- the run did not do its job" >&2
    exit 1
  fi
else
  echo "production is unchanged -- top it up with \`task rounds:topup\` after a review pass, or let the cron."
fi
