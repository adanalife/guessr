#!/usr/bin/env bash
# Move a round set's media between the laptop that cuts it and the bucket that
# serves it. `clips.sh push` after generating, or `clips.sh push <file>...` to
# replace named objects; `clips.sh pull` to get a playable copy onto a machine
# with no corpus.
#
# web/clips/ is gitignored: a set is ~150 MB of mp4 and this repo is public, so
# committing one would add that to history on every regeneration, for good.
#
# ONE OBJECT PER CLIP, keyed by the name the round carries. The key is exactly the
# `image` value in the `rounds` table (`clips/<name>.mp4`), so there is no mapping
# to keep in step: what a round says it is, is where its bytes are.
#
# Per object rather than one archive per set, because the endpoint reads the
# bucket at request time: a single clip can be replaced without republishing 300,
# and a regeneration uploads only what is new.
#
# Nothing here ever deletes. An object is load-bearing for as long as any round
# names it, and at ~0.5 MB a clip against 10 GB of free storage there is no
# pressure to work out which. That covers the `clips-*.tar` objects from the
# archive layout too -- a release tagged back then still pulls one.
set -euo pipefail

BUCKET="${BUCKET:-adanalife-guessr-clips}"
# Which schedule `pull` fetches the media for. Staging by default: it is the tier
# a generation run writes, so it is the one whose clips might not be here yet.
DB="${DB:-adanalife-guessr-answers-staging}"
WEB="$(cd "$(dirname "$0")" && pwd)/web"
# Eight at a time. Each object is its own `npx wrangler` process, so this is almost
# entirely spent waiting on the network; sequentially a 300-clip set takes minutes
# rather than seconds. Not higher, because wrangler is a node startup each time and
# the laptop is being typed on.
JOBS="${JOBS:-8}"

# Every clip some date is scheduled to play, straight from the database that
# decides it. That is the list players will actually ask for, which makes it the
# right list to pull -- a file in web/clips/ no round names is a leftover, and an
# object no round names is history.
#
# From D1 rather than from a file: the schedule *is* the round set, and a machine
# with no corpus -- the whole reason `pull` exists -- has no local copy of it.
scheduled_clips() {
  npx wrangler d1 execute "$DB" --remote --json \
    --command="SELECT image FROM round_days ORDER BY date, position" \
    | jq -r '.[0].results[].image | sub("^clips/"; "")'
}

verb="${1:?usage: clips.sh push [file...]|pull}"
shift

case "$verb" in
  push)
    # Named files push just those; no arguments pushes the whole directory. The
    # single-file form is what `rounds:rebuild` uses to replace one object, and it
    # goes through here rather than calling wrangler itself so a rebuild inherits
    # the retry loop and the explicit content type.
    if [ "$#" -gt 0 ]; then
      files=$(printf '%s\n' "$@")
    else
      test -d "$WEB/clips" || { echo "no web/clips/ to push -- run \`task rounds\`" >&2; exit 1; }
      files=$(find "$WEB/clips" -name '*.mp4')
    fi
    count=$(printf '%s' "$files" | grep -c . || true)
    test "$count" -gt 0 || { echo "nothing to push (no mp4s)" >&2; exit 1; }
    echo "pushing $count clips to $BUCKET, $JOBS at a time"
    # --content-type explicitly, even though the endpoint sets it on the way out
    # too. An object stored as octet-stream is a <video> that plays nothing and
    # reports nothing, and belt-and-braces is cheap on the one failure mode that is
    # invisible from both ends.
    # The bucket and the file arrive as $1 and $2 rather than being interpolated
    # into the script text: nesting a quote inside a single-quoted `sh -c` string
    # works but reads as a mistake, and this way the inner script is literal.
    #
    # Three attempts per object, because one flaked answer from Cloudflare's API
    # must not cost the whole run: a put is idempotent (the name is the moment,
    # the bytes are the same bytes), the failure already seen for real was a 523
    # from api.cloudflare.com's own gateway, and by the time a scheduled job is
    # pushing it has spent half an hour generating what one blip would throw
    # away. Ten seconds and out -- an outage that survives three spaced attempts
    # fails the run, which is what the weekly cadence's failure budget is for.
    # shellcheck disable=SC2016  # deliberate: $1/$2/$3 are the inner sh's own
    # positional parameters, passed after the script, not this shell's.
    printf '%s\n' "$files" | tr '\n' '\0' \
      | xargs -0 -P "$JOBS" -I{} sh -c \
        'n=0
         until npx wrangler r2 object put "$1/clips/$(basename "$2")" \
                 --file "$2" --content-type video/mp4 --remote >/dev/null; do
           n=$((n + 1))
           if [ "$n" -ge 3 ]; then
             echo "gave up on $(basename "$2") after $n attempts" >&2
             exit 1
           fi
           echo "attempt $n failed for $(basename "$2"), retrying" >&2
           sleep $((n * 5))
         done' \
        sh "$BUCKET" {}
    echo "ok: a round naming any of these clips can now be played"
    ;;

  pull)
    # For a machine with no corpus that wants a local copy of the scheduled set.
    # No deploy runs this -- the endpoint reads the bucket at request time, which
    # is the whole point -- so it is a development convenience, and a way to check
    # by hand that a push landed.
    mkdir -p "$WEB/clips"
    want_list=$(scheduled_clips)
    test -n "$want_list" || { echo "$DB has no schedule to pull for" >&2; exit 1; }
    # shellcheck disable=SC2016  # deliberate: $1/$2/$3 are the inner sh's own
    # positional parameters, passed after the script, not this shell's.
    printf '%s\n' "$want_list" | tr '\n' '\0' \
      | xargs -0 -P "$JOBS" -I{} sh -c \
        'test -f "$2/clips/$3" && exit 0
         npx wrangler r2 object get "$1/clips/$3" \
           --file "$2/clips/$3" --remote >/dev/null' \
        sh "$BUCKET" "$WEB" {}
    have=$(find "$WEB/clips" -name '*.mp4' | wc -l | tr -d ' ')
    want=$(printf '%s\n' "$want_list" | wc -l | tr -d ' ')
    # A shortfall means a scheduled round's media was never pushed -- which, since
    # a deployment reads the bucket at request time, is a black pane in somebody's
    # game rather than a deploy that fails.
    test "$have" -ge "$want" || {
      echo "::error::have $have of $want clips. Media for a round $DB has" >&2
      echo "::error::scheduled was never pushed -- run \`task clips:push\` from" >&2
      echo "::error::the laptop that generated it." >&2
      exit 1
    }
    echo "ok: $want clips in web/clips/"
    ;;

  *) echo "usage: clips.sh push [file...]|pull" >&2; exit 1 ;;
esac
