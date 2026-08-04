#!/usr/bin/env bash
# Move a round set's media between the laptop that cuts it and the bucket that
# serves it. `clips.sh push` after generating; `clips.sh pull` to get a playable
# copy onto a machine with no corpus.
#
# web/clips/ is gitignored: a set is ~150 MB of mp4 and this repo is public, so
# committing one would add that to history on every regeneration, for good.
#
# ONE OBJECT PER CLIP, keyed by the name the manifest uses. The key is exactly the
# `image` value a round carries (`clips/<name>.mp4`), so there is no mapping to
# keep in step: what a round says it is, is where its bytes are.
#
# It used to be one tarball per *set*, named after a hash of web/rounds.json. That
# was the right shape while the clips were deployed assets -- content-addressing
# the archive made "this manifest, these clips" unrepresentable rather than merely
# unlikely -- and it is the wrong shape now they are read from the bucket at
# request time. Under the tarball a round set could only reach players through a
# deploy, because a deploy was the thing that unpacked it. Per-object also means a
# single clip can be replaced without republishing 300, and a regeneration uploads
# only what is new.
#
# Nothing here ever deletes. An object is load-bearing for as long as any round
# names it, and at ~0.5 MB a clip against 10 GB of free storage there is no
# pressure to work out which. The old clips-*.tar objects are left alone for the
# same reason: a release tagged before this change still pulls one.
set -euo pipefail

BUCKET="${BUCKET:-adanalife-guessr-clips}"
WEB="$(cd "$(dirname "$0")" && pwd)/web"
# Eight at a time. Each object is its own `npx wrangler` process, so this is almost
# entirely spent waiting on the network; sequentially a 300-clip set takes minutes
# rather than seconds. Not higher, because wrangler is a node startup each time and
# the laptop is being typed on.
JOBS="${JOBS:-8}"

# Every clip the committed manifest names. That is the list a deployment will ask
# for, which makes it the right list to pull -- a file in web/clips/ no round names
# is a leftover, and an object no round names is history.
manifest_clips() {
  test -f "$WEB/rounds.json" || { echo "no web/rounds.json to read" >&2; exit 1; }
  jq -r '.[].image | sub("^clips/"; "")' "$WEB/rounds.json"
}

case "${1:?usage: clips.sh push|pull}" in
  push)
    test -d "$WEB/clips" || { echo "no web/clips/ to push -- run \`task rounds\`" >&2; exit 1; }
    count=$(find "$WEB/clips" -name '*.mp4' | wc -l | tr -d ' ')
    test "$count" -gt 0 || { echo "web/clips/ holds no mp4s" >&2; exit 1; }
    echo "pushing $count clips to $BUCKET, $JOBS at a time"
    # --content-type explicitly, even though the endpoint sets it on the way out
    # too. An object stored as octet-stream is a <video> that plays nothing and
    # reports nothing, and belt-and-braces is cheap on the one failure mode that is
    # invisible from both ends.
    # The bucket and the file arrive as $1 and $2 rather than being interpolated
    # into the script text: nesting a quote inside a single-quoted `sh -c` string
    # works but reads as a mistake, and this way the inner script is literal.
    # shellcheck disable=SC2016  # deliberate: $1/$2/$3 are the inner sh's own
    # positional parameters, passed after the script, not this shell's.
    find "$WEB/clips" -name '*.mp4' -print0 \
      | xargs -0 -P "$JOBS" -I{} sh -c \
        'npx wrangler r2 object put "$1/clips/$(basename "$2")" \
           --file "$2" --content-type video/mp4 --remote >/dev/null' \
        sh "$BUCKET" {}
    echo "ok: a manifest naming these clips can now be deployed"
    ;;

  pull)
    # For a machine with no corpus that wants to play the committed set locally.
    # The deploy workflows no longer run this -- the endpoint reads the bucket at
    # request time, which is the whole point -- so this is a development
    # convenience, and a way to check by hand that a push landed.
    mkdir -p "$WEB/clips"
    # shellcheck disable=SC2016  # deliberate: $1/$2/$3 are the inner sh's own
    # positional parameters, passed after the script, not this shell's.
    manifest_clips | tr '\n' '\0' \
      | xargs -0 -P "$JOBS" -I{} sh -c \
        'test -f "$2/clips/$3" && exit 0
         npx wrangler r2 object get "$1/clips/$3" \
           --file "$2/clips/$3" --remote >/dev/null' \
        sh "$BUCKET" "$WEB" {}
    have=$(find "$WEB/clips" -name '*.mp4' | wc -l | tr -d ' ')
    want=$(manifest_clips | wc -l | tr -d ' ')
    # A shortfall means the committed manifest names clips that were never pushed
    # -- which, now a deployment reads the bucket at request time, is a game of
    # 404s rather than a deploy that fails.
    test "$have" -ge "$want" || {
      echo "::error::have $have of $want clips. The media for the committed" >&2
      echo "::error::web/rounds.json was never pushed -- run \`task clips:push\`" >&2
      echo "::error::from the laptop that generated it." >&2
      exit 1
    }
    echo "ok: $want clips in web/clips/"
    ;;

  *) echo "usage: clips.sh push|pull" >&2; exit 1 ;;
esac
