#!/usr/bin/env bash
# Run the game against a real local D1 and assert the endpoints answer.
#
# `smoke.sh` is this for a deployed tier; this is the same idea against a
# database and a runtime that live and die with the run. What it buys over the
# unit tests is the half they structurally cannot reach: _d1.mjs is a stub over
# node:sqlite that models the *shape* of the binding, so it proves a handler's
# logic and says nothing about whether Pages routes to it, whether the binding is
# wired, or how a real D1 answers. Those are exactly the failures that have cost
# a deploy each -- an endpoint that 500s on a table nobody created reads,
# end-to-end, as a perfectly green build.
#
# The database is workerd's own SQLite via wrangler --local, and the server is
# `wrangler pages dev` -- the same runtime a deployment gets. No new dependency:
# wrangler is already here.
#
# NOT covered, deliberately: the clip endpoint. It streams from an R2 binding,
# and a local bucket seeded with a fixture mp4 would prove the handler runs
# without proving the thing that keeps breaking, which is whether the *deployed*
# project has the binding. smoke.sh owns that, against a real tier.
set -euo pipefail

cd "$(dirname "$0")"

PORT="${PORT:-8788}"
BASE="http://127.0.0.1:$PORT"
DB="${DB:-guessr-answers-local}"
DAYS="${DAYS:-5}"

fail() { echo "::error::$*" >&2; exit 1; }

# Everything this touches is disposable: a fresh .wrangler state, and the two
# generated files, which are gitignored and belong to whoever ran `task rounds`
# last. Refuse to clobber a real set rather than silently replacing it.
for f in rounds.sql answers.sql; do
  if [ -s "$f" ] && ! grep -q "'fixture'" "$f" 2>/dev/null; then
    fail "$f looks like a real round set. Move it aside before running this."
  fi
done

echo "== fixture"
python3 fixture.py --days "$DAYS"

echo "== migrations"
# The real path a deployed database takes, not a concatenation of the files: this
# is the run that would catch a migration wrangler refuses even though sqlite3
# parsed it.
npx wrangler d1 migrations apply "$DB" --local --config wrangler.d1.jsonc </dev/null

echo "== seed"
npx wrangler d1 execute "$DB" --local --config wrangler.d1.jsonc --file answers.sql --yes >/dev/null
npx wrangler d1 execute "$DB" --local --config wrangler.d1.jsonc --file rounds.sql --yes >/dev/null

echo "== server"
npx wrangler pages dev web/ --port "$PORT" --d1 "ANSWERS=$DB" >/tmp/pages-dev.log 2>&1 &
server=$!
# Kill the process group: `npx` forks wrangler, which forks workerd, so killing
# the pid this shell knows about leaves the port held and the next run fails to
# bind for reasons that look nothing like the cause.
trap 'kill -- -'"$server"' 2>/dev/null || kill '"$server"' 2>/dev/null || true' EXIT

for _ in $(seq 1 60); do
  curl -sf -o /dev/null "$BASE/version.json" 2>/dev/null && break
  curl -sf -o /dev/null "$BASE/" 2>/dev/null && break
  kill -0 "$server" 2>/dev/null || { cat /tmp/pages-dev.log; fail "the dev server exited"; }
  sleep 1
done

check() { # name, expected, actual
  [ "$2" = "$3" ] || fail "$1: expected $2, got $3"
  echo "ok: $1 -> $3"
}

status() { curl -s -o /tmp/int-body.json -w '%{http_code}' "$@"; }

today=$(date -u +%F)
future=$(python3 -c "import datetime as d;print(d.date.today()+d.timedelta(days=400))")

# The one that would have caught the failure this exists for: a database with no
# schema answers 500 here, and every other check in the suite still passes.
check "today's game is served" 200 "$(status "$BASE/api/day?date=$today")"
rounds=$(jq -r '.rounds | length' /tmp/int-body.json)
check "it is a full game" 5 "$rounds"

# Ramp order, through the real query rather than the stub's.
first=$(jq -r '.rounds[0].image' /tmp/int-body.json)
jq -e '[.rounds[].image] | length == (. | unique | length)' /tmp/int-body.json >/dev/null \
  || fail "a round was served twice in one game"

# A round reaches the browser as a name and nothing else. Asserted against the
# real serialisation, because this is the leak that ends the game.
jq -e '[.rounds[] | keys] | flatten | unique == ["image"]' /tmp/int-body.json >/dev/null \
  || fail "a served round carried more than its name: $(cat /tmp/int-body.json)"

check "an unopened date is refused" 403 "$(status "$BASE/api/day?date=$future")"
check "a malformed date is refused" 400 "$(status "$BASE/api/day?date=nope")"
check "practice draws from closed days" 200 "$(status "$BASE/api/day?practice")"

# Scoring, which is the other side of the same rows: the round just handed out
# has to be one this accepts, and its answer has to be there to score against.
score() { status -X POST "$BASE/api/score" -H 'content-type: application/json' -d "$1"; }

check "a practice guess scores" 200 \
  "$(score "{\"image\":\"$first\",\"lat\":40,\"lng\":-100}")"
jq -e '.recorded == false' /tmp/int-body.json >/dev/null || fail "practice was recorded"

check "a daily play records" 200 \
  "$(score "{\"image\":\"$first\",\"lat\":40,\"lng\":-100,\"date\":\"$today\",\"player_id\":\"a3f1c2d4-0000-4000-8000-000000000000\"}")"
jq -e '.recorded == true' /tmp/int-body.json >/dev/null || fail "a daily play was not recorded"

# A round scheduled for a different date must not score against today, which is
# the whole of what stops five known names buying an unlimited board position.
other=$(curl -s "$BASE/api/day?date=$(python3 -c "import datetime as d;print(d.date.today()-d.timedelta(days=1))")" | jq -r '.rounds[0].image')
if [ "$other" != "null" ] && [ "$other" != "$first" ]; then
  check "another date's round is refused" 403 \
    "$(score "{\"image\":\"$other\",\"lat\":40,\"lng\":-100,\"date\":\"$today\",\"player_id\":\"a3f1c2d4-0000-4000-8000-000000000000\"}")"
fi

check "an unknown round is refused" 404 \
  "$(score '{"image":"clips/not-a-real-round.mp4","lat":40,"lng":-100}')"

# The boards read, which is the check that a migration left `plays` intact.
for board in daily monthly; do
  check "the $board board reads" 200 "$(status "$BASE/api/leaderboard?board=$board")"
done

echo "ok: the game runs end to end against a real local D1"
