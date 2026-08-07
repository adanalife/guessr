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
# an edge cache for a while longer. The /api/day check below covers both that and
# routing, since it is a Function reading the live database.
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

# And the round set, separately, because version.json moving does not mean the
# game is playable. This used to byte-compare a committed manifest; the set is
# not deployed at all now, so the useful question is the one a player asks --
# does this tier have a game for today?
#
# Which also covers what the version pin cannot. version.json is new bytes every
# deploy, so it goes green the instant the deployment is live; /api/day is a
# Function reading the live database, so waiting on it proves routing works AND
# that a schedule was actually pushed. A deploy can now be flawless against a
# database nobody seeded, and this is the only thing that would say so.
#
# UTC today, which is always inside the play window: a date opens at 10:00 UTC on
# the day before it and closes at 12:00 UTC on the day after.
today=$(date -u +%F)
for _ in $(seq 1 40); do
  status=$(curl -s -o /tmp/smoke-day.json -w '%{http_code}' "$BASE/api/day?date=$today")
  rounds=$(jq -r '.rounds | length' /tmp/smoke-day.json 2>/dev/null || echo 0)
  [ "${rounds:-0}" -gt 0 ] && break
  sleep 3
done
day=$(cat /tmp/smoke-day.json)
if [ "${rounds:-0}" -eq 0 ]; then
  echo "::error::$BASE serves no game for $today, so it is not playable."
  # Three failures land here and they have three different fixes. Saying which is
  # the whole value of the check -- the alternative is what the clips endpoint did
  # on 2026-08-03, where a 500 was reported as "the media was never pushed" and
  # the suggested fix could not have worked.
  case "$status" in
    500) echo "::error::The endpoint threw, which at this point means the query" >&2
         echo "::error::hit a table that is not there. schema.sql has never been" >&2
         echo "::error::applied to this tier's database -- run \`task" >&2
         echo "::error::schema:stage:push\`. Pushing a round set will not fix it." >&2 ;;
    404) echo "::error::The endpoint answered, and round_days has nothing for" >&2
         echo "::error::today. Run \`task rounds:stage:push\` with a set whose" >&2
         echo "::error::schedule covers this date." >&2 ;;
    *)   echo "::error::HTTP $status, which is neither a missing table (500) nor" >&2
         echo "::error::an unscheduled date (404) -- so /api/day is not routing." >&2
         echo "::error::Response: $(head -c 200 /tmp/smoke-day.json)" >&2 ;;
  esac
  exit 1
fi
echo "ok: serving a game for $today -> $rounds rounds"

check() { # name, expected status, actual status, body
  if [ "$2" != "$3" ]; then
    echo "::error::$1 expected HTTP $2, got $3: $4"
    exit 1
  fi
  echo "ok: $1 -> $3"
}

post() { call -X POST "$BASE/api/score" \
  -H 'content-type: application/json' -d "$1"; }

# From the response above rather than fetched again: that is the round this tier
# would actually hand a player first today, so it is the one worth proving is
# playable.
image=$(printf '%s' "$day" | jq -r '.rounds[0].image')

# The media, which is the half no deploy carries: each clip is streamed out of R2
# by functions/clips/[[path]].js at request time, so a schedule naming clips that
# were never pushed produces a game of black panes even though the deploy itself
# had nothing to get wrong.
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
    404) echo "::error::The endpoint found no such object, so the media for a" >&2
         echo "::error::round scheduled today was never pushed. Run" >&2
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
# has.
#
# Retried, and the retry is load-bearing rather than a nicety. An object pushed
# to R2 a minute ago can still answer a truncated body -- the same per-asset
# propagation lag Pages has, reaching objects a Function streams too -- and
# ffprobe reads short bytes as `Invalid data found`. That is what failed the
# staging deploy of 2026-08-05 on a clip which was 1280x674 and correctly cropped
# the whole time, and which the identical assertion passed on 90 s later.
#
# Worth more care than an ordinary flake, because of which assertion this is: the
# only thing standing between a clip with the coordinates burned into it and the
# served game. A check that cries wolf is a check somebody learns to clear by
# hitting re-run, and that is the path a real HUD leak would take through.
clip=$(mktemp); trap 'rm -f "$clip"' EXIT
for attempt in 1 2 3 4 5; do
  # Truncated first: curl leaves the previous attempt's bytes in place when it
  # cannot write new ones, and ffprobe would then read a stale success.
  : >"$clip"
  read -r bytes code <<<"$(curl -s -o "$clip" -w '%{size_download} %{http_code}' "$BASE/$image")"
  dim=$(ffprobe -v error -select_streams v:0 -show_entries stream=width,height \
    -of csv=p=0 "$clip" 2>/dev/null || true)
  case "$dim" in [0-9]*,[0-9]*) break ;; esac
  if [ "$attempt" -lt 5 ]; then sleep $((attempt * 3)); fi
done

# Unreadable is NOT uncropped, and conflating them was the other half of that
# false alarm. Bytes ffprobe cannot decode carry no aspect ratio at all, so they
# are silent on whether the strip came off -- reporting them as an uncropped clip
# names a cause that isn't, and sends someone to regenerate a set that is fine.
# So the crop is only ever judged on dimensions that were actually read.
case "$dim" in
  [0-9]*,[0-9]*) ;;
  *) echo "::error::$image came back as $bytes bytes (HTTP $code) that ffprobe"
     echo "::error::cannot decode, on 5 tries over ~30s. That is the media, not"
     echo "::error::the crop: undecodable bytes say nothing either way about the"
     echo "::error::HUD strip. Fetch the object out of R2 and look at it before"
     echo "::error::regenerating anything."
     exit 1 ;;
esac

w=${dim%%,*} h=${dim##*,}
if [ "$((w * 9))" -le "$((h * 16))" ]; then
  echo "::error::$image is ${dim}, which is not a cropped clip. The coordinates"
  echo "::error::the dashcam burns across the bottom of every frame are in the"
  echo "::error::footage this deployment is serving. Regenerate the set."
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

# The one property /api/day adds. While the draw was a seeded shuffle the browser
# could run, a future date was derivable and there was nothing to protect; now the
# server is the only thing that knows next month's rounds, so refusing to say is
# the whole of the protection.
out=$(call "$BASE/api/day?date=2099-01-01")
check "an unopened date is refused" 403 "$(tail -1 <<<"$out")" "$(head -1 <<<"$out")"

# And the admin surface, which is the same date served the opposite way --
# answers attached, window ignored. This script carries no Access token, so it is
# exactly the anonymous visitor the login exists to turn away, and both the page
# and the endpoint under it have to say no. Whichever tier this is: the surface is
# reachable through the Access-fronted pages.dev hostname and nowhere else, and a
# custom domain answering anything but a refusal is the leak.
#
# 403 is signed-out. 503 is a deployment with no Access application configured,
# which is a refusal too but a different fact worth saying out loud: on
# production that is the intended resting state, and on staging it means the
# page does not work for its operator either.
#
# 2099-01-01 has no schedule, so nothing here reads a real day to find out.
#
# What this no longer covers is `env.ASSETS`: the tier read now fails closed into
# the same 403 as being signed out, so a version.json the Functions cannot see is
# invisible from out here. test_admin_day.mjs carries that case instead.
for path in "/admin/" "/admin/day?date=2099-01-01"; do
  out=$(call "$BASE$path")
  status=$(tail -1 <<<"$out")
  case "$status" in
    403) echo "ok: $path refuses an unauthenticated request -> 403" ;;
    503) echo "ok: $path is closed -> 503, no Access application configured here" ;;
    *)   echo "::error::$BASE$path answered $status to a request carrying no Access"
         echo "::error::token. Anyone with the URL can read tomorrow's answers."
         head -1 <<<"$out"
         exit 1 ;;
  esac
done

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

# The live-stream resolver, asserted on its value and not merely on the key. The
# previous version of this check accepted any response carrying a "videoId" key,
# which a permanently-null resolver satisfies -- so a resolver that never once
# worked shipped green through two releases while the board quietly showed a link.
# A real id is assertable because it does not depend on the channel being live
# this second: the resolver answers the channel's newest video, and the channel
# has videos whether or not the van is moving.
#
# Retried, because the endpoint predates the resolver that works and call() will
# not catch that: an older build of this Function answers valid JSON carrying a
# null, which is not the `<`-body signature, so the assertion lands on the
# previous deployment's answer and reads it as a broken resolver. That is what
# failed the v1.1.0 release, on a resolver that answered a real id the moment the
# routing finished cutting over. version.json cannot pin this away -- it is new
# bytes every deploy and goes green first, which is exactly what leaves an
# unchanged route still answering from the build before.
for _ in $(seq 1 20); do
  out=$(call "$BASE/api/live")
  grep -qE '"videoId":"[A-Za-z0-9_-]{11}"' <<<"$out" && break
  sleep 3
done
check "the live resolver answers" 200 "$(tail -1 <<<"$out")" "$(head -1 <<<"$out")"
grep -qE '"videoId":"[A-Za-z0-9_-]{11}"' <<<"$out" || {
  echo "::error::/api/live resolved no video id on 20 tries over ~60s -- got:"
  echo "::error::$(head -1 <<<"$out")"
  echo "::error::Past the propagation window, so this is the resolver: the feed"
  echo "::error::read is in the response's \"why\", and a 200 carrying no"
  echo "::error::<yt:videoId> means YouTube changed the feed shape."
  exit 1; }
