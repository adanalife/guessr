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
# STAGING ONLY, all three. Production is a promotion, run by hand after a review
# pass -- not something a scheduled job reaches. That is the whole security
# posture of running this on a cron, and it costs one command a month.
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

# Both credentials up front, before the 25 minutes of encoding rather than after.
# Discovering a missing token at the first publish step means paying for the whole
# generation again, and this runs somewhere nobody is watching.
: "${CLOUDFLARE_ACCOUNT_ID:?needed by clips.sh and wrangler}"
: "${CLOUDFLARE_API_TOKEN:?needs R2 write on the clips bucket and D1 write on staging}"

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

echo "== 2/3 answers to the staging D1"
npx wrangler d1 execute "$STAGE_DB" --remote --file answers.sql --yes

# Last, and only now: the schedule, which is the thing that gives a date a game.
echo "== 3/3 pool and schedule to the staging D1"
npx wrangler d1 execute "$STAGE_DB" --remote --file rounds.sql --yes

# What a reviewer needs, and what a Discord notification will carry: how much was
# generated and how far ahead the game is now covered. Read back out of the
# database rather than out of the local files, so it describes what actually
# landed.
scheduled=$(npx wrangler d1 execute "$STAGE_DB" --remote --json \
  --command="SELECT count(DISTINCT date) AS days, max(date) AS through FROM round_days" \
  | jq -r '.[0].results[0] | "\(.days) days, through \(.through)"')

echo "published to staging: $scheduled"
echo "production is unchanged -- promote it by hand after a review pass."
