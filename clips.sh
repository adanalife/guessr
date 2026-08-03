#!/usr/bin/env bash
# Move a round set's media between the laptop that cuts it and the deploys that
# serve it. `clips.sh push` from the laptop, `clips.sh pull` from CI.
#
# web/clips/ is gitignored: a set is ~150 MB of mp4 and this is a public repo,
# so committing one would add that to history on every regeneration, for good.
# The manifest stays in git and the media comes through R2 instead.
#
# THE OBJECT IS NAMED AFTER THE MANIFEST, which is the part worth understanding.
# The key is a hash of web/rounds.json, so a given manifest can only ever find
# the media that was pushed alongside it. Under a fixed name like clips.tar, a
# regeneration would overwrite the tarball that production -- still serving an
# older release, with an older manifest in it -- pulls on its next deploy, and
# production would come back up naming clips that are no longer in the bucket.
# Content-addressing the object makes that unrepresentable rather than merely
# unlikely: a manifest with no matching object fails the pull loudly, and one
# with a matching object provably has its own media.
#
# The corollary is that nothing here ever deletes. An old tarball is what some
# deployed manifest still points at.
#
# One tarball rather than 300 objects because a deploy is then one request
# instead of 300 -- about ten seconds against four minutes, on every deploy of
# every tier.
set -euo pipefail

BUCKET="${BUCKET:-adanalife-guessr-clips}"
WEB="$(cd "$(dirname "$0")" && pwd)/web"

# sha256sum on the Linux runners, shasum on macOS. Same digest either way.
digest() {
  if command -v sha256sum >/dev/null 2>&1; then sha256sum "$1"; else shasum -a 256 "$1"; fi
}

# Sixteen hex characters. This names an object in a private bucket rather than
# defending against anything, and a full digest makes the log lines unreadable.
key() {
  test -f "$WEB/rounds.json" || { echo "no web/rounds.json to key against" >&2; exit 1; }
  printf 'clips-%.16s.tar\n' "$(digest "$WEB/rounds.json" | cut -d' ' -f1)"
}

case "${1:?usage: clips.sh push|pull|key}" in
  key) key ;;

  push)
    k=$(key)
    test -d "$WEB/clips" || { echo "no web/clips/ to push -- run \`task rounds\`" >&2; exit 1; }
    # Bare mktemp, no -t: BSD treats its argument as a prefix and GNU treats it
    # as a template needing literal X's, so the portable spelling is neither.
    tmp=$(mktemp); trap 'rm -f "$tmp"' EXIT
    # -C so the archive holds clips/x.mp4 rather than the absolute path, which
    # is what lets the pull side extract straight into web/.
    tar -cf "$tmp" -C "$WEB" clips
    echo "pushing $k ($(du -h "$tmp" | cut -f1), $(find "$WEB/clips" -name '*.mp4' | wc -l | tr -d ' ') clips)"
    npx wrangler r2 object put "$BUCKET/$k" \
      --file "$tmp" --content-type application/x-tar --remote
    echo "ok: web/rounds.json can now be deployed"
    ;;

  pull)
    k=$(key)
    # Bare mktemp, no -t: BSD treats its argument as a prefix and GNU treats it
    # as a template needing literal X's, so the portable spelling is neither.
    tmp=$(mktemp); trap 'rm -f "$tmp"' EXIT
    # A miss here is the whole reason this is content-addressed: it means the
    # committed manifest names a set that was never uploaded, which is otherwise
    # a green deploy full of black panes.
    if ! npx wrangler r2 object get "$BUCKET/$k" --file "$tmp" --remote 2>&1; then
      echo "::error::could not fetch $k from $BUCKET. Either the media for the"
      echo "::error::committed web/rounds.json was never pushed -- run \`task clips:push\`"
      echo "::error::from the laptop that generated it -- or this token is missing"
      echo "::error::R2 read on the bucket. wrangler's own error is above; it says"
      echo "::error::which."
      exit 1
    fi
    tar -xf "$tmp" -C "$WEB"
    echo "ok: pulled $(find "$WEB/clips" -name '*.mp4' | wc -l | tr -d ' ') clips from $k"
    ;;

  *) echo "usage: clips.sh push|pull|key" >&2; exit 1 ;;
esac
