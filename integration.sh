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
# The assertions are contract.py's: every route, its statuses, its shapes and its
# guards, over HTTP only, so they hold whatever language serves them. This file
# only builds the world they run against and tears it down.
#
# The clip route runs against a local bucket seeded with one stand-in object.
# That proves the handler -- content type, ranges, a bare 404 for a missing
# object -- and nothing about the deployment, whose failure mode is a Pages
# project without the binding at all. smoke.sh owns that, against a real tier.
set -euo pipefail

cd "$(dirname "$0")"

PORT="${PORT:-8788}"
BASE="http://127.0.0.1:$PORT"
DB="${DB:-guessr-answers-local}"
# Six, because the admin reject is paid for out of the furthest day, and it has to
# lie beyond one that is never open yet (see contract.py).
DAYS="${DAYS:-6}"
BUCKET=guessr-clips-local

fail() { echo "::error::$*" >&2; exit 1; }

# Everything local lives here and dies with the run, so no run inherits another's
# plays or a schedule an earlier reject rearranged, and `task dev`'s database is
# never touched.
STATE=$(mktemp -d)
server=""
stamped=""
cleanup() {
  # Kill the process group: `npx` forks wrangler, which forks workerd, so killing
  # the pid this shell knows about leaves the port held and the next run fails to
  # bind for reasons that look nothing like the cause.
  if [ -n "$server" ]; then
    kill -- -"$server" 2>/dev/null || kill "$server" 2>/dev/null || true
  fi
  # The tier stamp is this run's; a copy `task dev` left goes back where it was.
  if [ -n "$stamped" ]; then
    rm -f web/version.json
    if [ -f "$STATE/version.json" ]; then mv "$STATE/version.json" web/version.json; fi
  fi
  rm -rf "$STATE"
}
trap cleanup EXIT

# Everything this touches is disposable: a fresh wrangler state, and the two
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
npx wrangler d1 migrations apply "$DB" --local --persist-to "$STATE" --config wrangler.d1.jsonc </dev/null

echo "== seed"
d1() { npx wrangler d1 execute "$DB" --local --persist-to "$STATE" --config wrangler.d1.jsonc "$@"; }
d1 --file answers.sql --yes >/dev/null
d1 --file rounds.sql --yes >/dev/null
# A finished day with plays on it, which /api/score cannot make: it refuses a
# closed date, which is the point of it.
python3 contract.py --seed >"$STATE/plays.sql"
d1 --file "$STATE/plays.sql" --yes >/dev/null

# One object in the bucket: the opener of the furthest scheduled day, which is
# the round contract.py fetches as a clip and the reject takes as a replacement.
clip=$(d1 --json --command "SELECT image FROM round_days ORDER BY date DESC, position LIMIT 1" \
  | jq -r '.[0].results[0].image')
printf 'stand-in bytes, not a real mp4\n' >"$STATE/clip.mp4"
npx wrangler r2 object put "$BUCKET/$clip" --local --persist-to "$STATE" \
  --file "$STATE/clip.mp4" >/dev/null

echo "== server"
# Started with no tier, so the first pass sees /admin/ the way an unstamped
# deployment does.
stamped=1
if [ -f web/version.json ]; then mv web/version.json "$STATE/version.json"; fi
npx wrangler pages dev web/ --port "$PORT" --persist-to "$STATE" \
  --d1 "ANSWERS=$DB" --r2 "CLIPS=$BUCKET" >/tmp/pages-dev.log 2>&1 &
server=$!

for _ in $(seq 1 60); do
  curl -sf -o /dev/null "$BASE/version.json" 2>/dev/null && break
  curl -sf -o /dev/null "$BASE/" 2>/dev/null && break
  kill -0 "$server" 2>/dev/null || { cat /tmp/pages-dev.log; fail "the dev server exited"; }
  sleep 1
done

echo "== contract, no tier"
python3 contract.py "$BASE" locked

echo "== contract, tier local"
# What `task dev` stamps, and the one tier the admin gate waves through. Static
# assets are served live, so the server picks it up without a restart.
printf '{"label":"local","tier":"local"}\n' >web/version.json
for _ in $(seq 1 30); do
  [ "$(curl -s "$BASE/version.json" | jq -r '.tier?' 2>/dev/null)" = local ] && break
  sleep 1
done
python3 contract.py "$BASE"
