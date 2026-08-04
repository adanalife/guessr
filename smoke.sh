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

# Wait for the deployment under test rather than for whatever answers first.
# Cloudflare takes a few seconds to cut over, so assertions that start the moment
# `wrangler pages deploy` returns can land on the *previous* build: that is how
# v0.7.0 went red on a deploy that had in fact succeeded, asserting a window
# check which only existed in the build being deployed.
#
# version.json is stamped per deploy by every workflow that runs this -- the tag,
# the commit, the PR number -- and is gitignored, so the copy sitting here is the
# expectation and a laptop clone simply has none. No local copy, no gate.
#
# It pins only itself, though. Being stamped per deploy is what makes it a
# reliable *version* signal and also what makes it a poor proxy for anything
# else: it is new bytes every time, so it cuts over the instant the deployment
# is live, while an asset whose bytes did not change can still be answered from
# an edge cache for a while longer. The manifest pin below covers that, and the
# function-wait after it covers routing.
if [ -f web/version.json ]; then
  want=$(jq -r .label web/version.json)
  for _ in $(seq 1 40); do
    got=$(curl -s "$BASE/version.json" | jq -r .label 2>/dev/null || true)
    [ "$got" = "$want" ] && break
    sleep 3
  done
  if [ "$got" != "$want" ]; then
    echo "::error::$BASE still serves '$got', not the '$want' being deployed."
    echo "::error::Every assertion below would have described the previous build."
    exit 1
  fi
  echo "ok: serving the deployment under test -> $want"
else
  echo "note: no local web/version.json, so nothing pins which build answers"
fi

# And the round set, separately, because version.json moving does not mean it
# has. rounds.json changes only when the round set does, so it is exactly the
# asset that sits unchanged across deploys and lingers at the edge -- and it is
# the one every assertion below reads. v1.0.0 failed here: version.json already
# answered v1.0.0 while rounds.json was still the previous build's stills, so the
# clip check reported a jpg on a deploy that had in fact shipped 300 mp4s.
#
# Compared as bytes, because Pages serves the file verbatim and there is nothing
# cheaper that is actually conclusive -- spot-checking one round would pass a
# regenerated set that happened to keep its first one.
#
# Unconditional, unlike the version gate: rounds.json is committed, so the
# expectation is always here.
for _ in $(seq 1 40); do
  cmp -s <(curl -sf "$BASE/rounds.json") web/rounds.json && pinned=1 && break
  sleep 3
done
if [ -z "${pinned:-}" ]; then
  echo "::error::$BASE serves a rounds.json that is not the one being deployed."
  echo "::error::Every assertion below would have described the previous round set."
  exit 1
fi
echo "ok: serving the round set under test -> $(jq length web/rounds.json) rounds"

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

# Read locally: the pin above proved the deployment serves these exact bytes, so
# fetching them again would only add a way for the two to disagree.
image=$(jq -r '.[0].image' web/rounds.json)

# The media half of the round set, which is the half git does not carry: each clip
# is streamed out of R2 by functions/clips/[[path]].js at request time, so a
# manifest naming a set that was never pushed produces a game of black panes even
# though the deploy itself had nothing to get wrong.
#
# Status is no good for detecting it. Pages answers a path it has no file for
# with the game's own HTML and a 200, so the missing-media case and the
# everything-is-fine case are the same status code, the same colour in CI, and
# distinguishable only by content type.
#
# Retried while the answer is text/html for the same reason call() retries a `<`
# body: Pages answering a path it holds no file for is the not-yet-propagated
# signature, and on the first try it is indistinguishable from a tarball that was
# never pushed.
for _ in $(seq 1 20); do
  ctype=$(curl -s -o /dev/null -w '%{content_type}' "$BASE/$image")
  [ "${ctype%%;*}" = "text/html" ] || break
  sleep 3
done
if [ "${ctype%%;*}" != "video/mp4" ]; then
  # Say which of the two it is, because they have different fixes and the
  # symptom is identical: a clip that will not play. A 404 is the endpoint
  # working and finding nothing, so the media was never uploaded. A 500 is the
  # endpoint throwing, which at this point in its life means `env.CLIPS` is
  # undefined -- the bucket is not bound to this Pages project, and no amount of
  # pushing clips will help.
  status=$(curl -s -o /dev/null -w '%{http_code}' "$BASE/$image")
  echo "::error::$image served as '$ctype' (HTTP $status), not video/mp4."
  case "$status" in
    404) echo "::error::The endpoint found no such object, so the media for the" >&2
         echo "::error::committed web/rounds.json was never pushed. Run" >&2
         echo "::error::\`task clips:push\` from the laptop that generated it." >&2 ;;
    500) echo "::error::The endpoint threw, which means the CLIPS binding is" >&2
         echo "::error::missing from this Pages project -- see infra's" >&2
         echo "::error::cloudflare-pages-guessr.tf. Pushing clips will not fix it." >&2 ;;
    *)   echo "::error::Neither a missing object (404) nor a missing binding" >&2
         echo "::error::(500), so this is something else -- look at the response." >&2 ;;
  esac
  exit 1
fi
echo "ok: round media is served as video -> $image"

# And the same clip is HUD-cropped, on the bytes that actually shipped. The
# dashcam burns "49 MPH W71.606763 N42.822437" across the bottom of every frame,
# so an uncropped clip hands the answer to the player -- a game that still runs,
# still looks right, and is trivially cheatable.
#
# check.py asserts this too, but only where the media is, and the clips are
# gitignored -- so that is the laptop that generated them and nowhere else. `task
# clips:push` is the one gate, and it is a gate a human has to remember; nothing
# in CI ever sees a clip. So this is the same assertion moved to the one place
# that sees every tier: a real deployment.
#
# Wider than 16:9 is the whole test. The crop takes a strip off the bottom and
# changes nothing else, so it is the one thing that cannot be true of a frame
# with the HUD still on it. Integers, because that is the arithmetic the shell
# has -- and an unreadable clip leaves both at 0, which fails the same way.
clip=$(mktemp); trap 'rm -f "$clip"' EXIT
curl -sf "$BASE/$image" -o "$clip"
dim=$(ffprobe -v error -select_streams v:0 -show_entries stream=width,height \
  -of csv=p=0 "$clip" || true)
w=${dim%%,*} h=${dim##*,}
if [ "$((w * 9))" -le "$((h * 16))" ]; then
  echo "::error::$image is '${dim:-unreadable}', which is not a cropped clip. The"
  echo "::error::coordinates the dashcam burns across the bottom of every frame are"
  echo "::error::in the footage this deployment is serving. Regenerate the set."
  exit 1
fi
echo "ok: round media is HUD-cropped -> ${dim}"

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

# The live-stream resolver. Asserted on the key and not on its value, because the
# value is whether the channel happens to be streaming right this second and a
# gate that fails when the van is parked is a gate nobody trusts. The key is the
# part a deploy can lose, and it is the same missing-endpoint-serves-HTML trap the
# boards guard against above.
out=$(call "$BASE/api/live")
check "the live resolver answers" 200 "$(tail -1 <<<"$out")" "$(head -1 <<<"$out")"
grep -q '"videoId"' <<<"$out" || { echo "::error::/api/live had no videoId key"; exit 1; }
