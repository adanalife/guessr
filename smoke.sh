#!/usr/bin/env bash
# Exercise the endpoints against a deployment, and fail if the game isn't
# playable on it. Takes the base URL: ./smoke.sh https://guessr.dana.lol
#
# Everything below the handler is untestable anywhere else: the unit tests cover
# the scoring curve and the draw, but the D1 bindings, the Pages routing and the
# cross-directory bundling of web/daily.js only exist in a real deploy.
#
# It guards the failure the README warns about and nothing enforced -- a
# regenerated round set whose answers were never pushed to D1, where every guess
# comes back "unknown round" on a deploy that looked green. And a missing table
# from an unapplied schema.sql surfaces here as a 500 rather than on the stream.
#
# Read-only by construction: a practice guess (no date) is scored and never
# recorded, and the two rejections return before the write path. So this leaves
# nothing behind in the database it runs against, production included.
set -euo pipefail

BASE="${1:?usage: smoke.sh <base-url>}"

# Every request goes through here, and it retries only while the answer is the
# *site* rather than a Function -- a body starting `<` is the game's HTML, which
# is what Pages serves for a path no Worker claims. That is the propagation
# signature: a deployment serves static assets from the edge before its Worker
# routing is live, so a request lands on the site and 404s. Retrying a
# not-the-Function answer costs a couple of seconds; retrying a real JSON answer
# would hide exactly the failures this exists to catch, so it never does.
call() {
  local out
  for _ in $(seq 1 20); do
    out=$(curl -s -w '\n%{http_code}' "$@")
    if ! grep -q '^<' <<<"$out"; then printf '%s' "$out"; return 0; fi
    sleep 3
  done
  printf '%s' "$out"
}

# Wait on a Function, not on a static asset: rounds.json can be served from the
# edge while /api/* still misses, which is how a green deploy produced an HTML
# 404 mid-run. The unknown-board 400 is the cheapest deterministic Function
# response there is, and touches no database.
for _ in $(seq 1 30); do
  if curl -s "$BASE/api/leaderboard?board=weekly" | grep -q '"error"'; then break; fi
  sleep 3
done

check() { # name, expected status, actual status, body
  if [ "$2" != "$3" ]; then
    echo "::error::$1 expected HTTP $2, got $3: $4"
    exit 1
  fi
  echo "ok: $1 -> $3"
}

post() { call -X POST "$BASE/api/score" \
  -H 'content-type: application/json' -d "$1"; }

image=$(curl -sf "$BASE/rounds.json" | jq -r '.[0].image')

# A practice guess: scored, never recorded. Fails if the answers table has never
# heard of the round set that just deployed.
out=$(post "{\"image\":\"$image\",\"lat\":40,\"lng\":-100}")
check "practice guess scores" 200 "$(tail -1 <<<"$out")" "$(head -1 <<<"$out")"
grep -q '"recorded":false' <<<"$out" || { echo "::error::practice guess was recorded"; exit 1; }

# A round nobody has answers for.
out=$(post '{"image":"clips/not-a-real-round.mp4","lat":40,"lng":-100}')
check "unknown round is refused" 404 "$(tail -1 <<<"$out")" "$(head -1 <<<"$out")"

# A date far enough out that no clock skew makes it open, so the window check is
# what refuses it.
out=$(post "{\"image\":\"$image\",\"lat\":40,\"lng\":-100,\"date\":\"2099-01-01\",\"player_id\":\"ci-smoke\"}")
check "a closed date is refused" 403 "$(tail -1 <<<"$out")" "$(head -1 <<<"$out")"

# Both boards read. A 500 here is an unapplied schema.sql.
#
# The shape assertion is not belt-and-braces: Pages serves the static site for a
# path no Function claims, so a missing endpoint answers 200 with the game's HTML
# and a status-only check sails past it.
for board in daily monthly; do
  out=$(call "$BASE/api/leaderboard?board=$board")
  check "$board board reads" 200 "$(tail -1 <<<"$out")" "$(head -1 <<<"$out")"
  grep -q '"rows"' <<<"$out" || { echo "::error::$board board had no rows key"; exit 1; }
done

out=$(call "$BASE/api/leaderboard?board=weekly")
check "an unknown board is refused" 400 "$(tail -1 <<<"$out")" "$(head -1 <<<"$out")"
