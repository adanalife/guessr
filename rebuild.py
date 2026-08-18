#!/usr/bin/env python3
"""Re-cut one round's clip from the corpus and put it back at the same key.

The recovery path for a clip that was deleted, corrupted, or never uploaded. Three
things that already ship assume this exists:

- `clip_name()` puts the moment in the filename specifically so a re-cut can land
  at the URL players already hold.
- `functions/clips/[[path]].js` serves clips with a year-long `immutable` cache
  header, which is only safe because a rebuild cannot put *different* footage at a
  name someone has cached.
- two closed TODO items name it as the recovery step for a stale `clip_ts_sec` and
  for watermarking a clip cut before the watermark existed.

It reuses `make_rounds.extract_clip`, so a rebuilt clip is the same crop, scale,
framerate, watermark and encoder settings as the original -- the point is the same
bytes, and a second copy of that ffmpeg invocation would drift from the first.

Provenance comes from the `rounds` row, not from the filename, even though the
filename encodes the same millisecond. The row carries `source_ts_sec` as well,
which is what distinguishes a clip whose corpus cut was trimmed (where the offset
is trim-relative and a later re-trim moves the footage) from the 97% that were
never trimmed. Cutting off the filename alone cannot tell those apart, and the one
thing this script must never do is quietly put different footage at a cached URL.

Needs the corpus, so this is a laptop or in-cluster command rather than a button.
"""

import argparse
import json
import subprocess
import sys
from pathlib import Path

from make_rounds import CORPUS, extract_clip

# Where the round pool lives per tier. A rebuild reads provenance and writes
# nothing, so pointing it at production is a SELECT; the bytes go to the one
# bucket both tiers serve from.
PROD_DB = "adanalife-guessr-answers"
STAGING_DB = "adanalife-guessr-answers-staging"

WEB = Path(__file__).parent / "web"


def parse_image(image: str) -> tuple[str, int | None]:
    """Split a clip key into its slug and, if the key carries one, its millisecond.

    `rpartition` on the last hyphen, because a slug may hold hyphens of its own
    and the millisecond field never does.

    None for a key with no moment in it. Those are the pre-guessr#81 naming, and
    production still schedules ten of them -- refusing to parse them would put the
    oldest rounds, the ones likeliest to have lost their media, out of reach of the
    tool that exists to restore it.
    """
    name = image.removeprefix("clips/").removesuffix(".mp4")
    slug, sep, ms = name.rpartition("-")
    if not sep or not ms.isdigit():
        return name, None
    return slug, int(ms)


def round_row(db: str, image: str) -> dict | None:
    """The `rounds` row naming this image, or None if no round does."""
    # No parameter binding in `d1 execute --command`, so the value is quoted the
    # way make_rounds.py quotes its generated SQL. An image is a filename this
    # script has already destructured, which is a narrower shape than that needs.
    quoted = image.replace("'", "''")
    out = subprocess.run(
        [
            "npx",
            "wrangler",
            "d1",
            "execute",
            db,
            "--remote",
            "--json",
            "--command",
            "SELECT slug, source_ts_sec, clip_ts_sec, status "
            f"FROM rounds WHERE image = '{quoted}'",
        ],
        capture_output=True,
        text=True,
        check=True,
    )
    results = json.loads(out.stdout)[0]["results"]
    return results[0] if results else None


def check(image: str, row: dict, ms: int | None, slug: str) -> list[str]:
    """Every reason not to overwrite this object, in one pass.

    Collected rather than raised one at a time so a single run reports everything
    wrong with the request -- the operator is on a laptop with the corpus mounted
    and a broken game, and a second round-trip per problem is the wrong shape.
    """
    problems = []
    if row["slug"] != slug:
        problems.append(
            f"the round says slug {row['slug']!r}, the key says {slug!r} -- "
            "one of them is wrong and guessing which would put the wrong road "
            "at this URL"
        )
    if ms is None:
        # A key from before the moment went into the filename. The row is then the
        # only record of which moment this is, and nothing corroborates it -- so a
        # wrong row means the wrong three seconds at a URL players hold.
        if not row["clip_ts_sec"] and not row["source_ts_sec"]:
            # Which is where all ten of production's legacy rounds sit: their
            # provenance columns were backfilled to zero when the pool adopted
            # them, so the moment they were cut at is recorded nowhere. Cutting at
            # 0s would put the start of the source clip at a URL that answers a
            # different stretch of road. There is nothing to rebuild from.
            problems.append(
                f"{image} records no moment -- not in the key, and the round's "
                "source_ts_sec and clip_ts_sec are both 0. The moment it was cut "
                "at is not stored anywhere, so this clip cannot be re-cut. "
                "Regenerating the round is the only path"
            )
        else:
            problems.append(
                f"{image} carries no moment in its key, so the round's "
                f"{row['clip_ts_sec']}s cannot be corroborated. Pass --force to "
                "cut there anyway"
            )
    elif round(row["clip_ts_sec"] * 1000) != ms:
        problems.append(
            f"the round was cut at {row['clip_ts_sec']}s, the key says "
            f"{ms / 1000}s. The key is what the cache promises, so a rebuild "
            "cannot honour both"
        )
    if not (CORPUS / f"{slug}.MP4").exists():
        problems.append(
            f"{CORPUS / f'{slug}.MP4'} is not there -- mount the corpus, or set "
            "GUESSR_CORPUS"
        )
    # Compared at the key's own resolution: a sub-millisecond difference cannot
    # name different frames at 30fps, and a trim delta is measured in seconds.
    if round(row["source_ts_sec"] * 1000) != round(row["clip_ts_sec"] * 1000):
        # The 3% (122 of 4,407) whose corpus cut was trimmed. Their offset is
        # relative to that cut, so if the trim has moved since the round was
        # generated, this millisecond names different footage than it did -- and
        # nothing records the trim to compare against, which is the open item in
        # video-pipeline's TODO. Recoverable by hand from source_ts_sec and the
        # trim delta; not something to do silently.
        problems.append(
            f"this clip's corpus cut was trimmed (source {row['source_ts_sec']}s "
            f"vs clip {row['clip_ts_sec']}s), so its offset is trim-relative. If "
            "the trim moved since the round was made, re-cutting here lands "
            "different footage at a cached URL. Pass --force once you have "
            "checked the trim is unchanged"
        )
    return problems


def main() -> int:
    ap = argparse.ArgumentParser(description=__doc__)
    ap.add_argument(
        "image", help="clips/<slug>-<milliseconds>.mp4, as the round names it"
    )
    ap.add_argument(
        "--db",
        default=PROD_DB,
        help=f"D1 database to read provenance from (default {PROD_DB}; "
        f"staging is {STAGING_DB})",
    )
    ap.add_argument(
        "--dry-run",
        action="store_true",
        help="cut into web/clips/ and stop, without replacing the object",
    )
    ap.add_argument(
        "--force",
        action="store_true",
        help="proceed despite a trimmed corpus cut (see the warning it prints)",
    )
    args = ap.parse_args()

    try:
        slug, ms = parse_image(args.image)
    except ValueError as e:
        print(f"error: {e}", file=sys.stderr)
        return 2
    # Rebuilt from the parse rather than passed through, so a key given without its
    # `clips/` prefix still names the object the round does.
    image = f"clips/{slug}.mp4" if ms is None else f"clips/{slug}-{ms:06d}.mp4"

    row = round_row(args.db, image)
    if row is None:
        # Nothing to restore to: the key is only meaningful as the clip some round
        # names, and bytes under a key no round names are unreachable by the game.
        print(
            f"error: no round in {args.db} names {image}. Nothing would serve a "
            "rebuild of it -- check the key, or the tier",
            file=sys.stderr,
        )
        return 1

    problems = check(image, row, ms, slug)
    if args.force:
        # --force covers the two "cannot be corroborated" refusals: a trimmed corpus
        # cut, and a key with no moment in it. It deliberately does not cover a key
        # and a row that flatly disagree, a missing corpus clip, or a moment nobody
        # recorded -- those are wrong inputs, not accepted risks.
        forceable = ("trim-relative", "cannot be corroborated")
        waived = [p for p in problems if any(f in p for f in forceable)]
        problems = [p for p in problems if p not in waived]
        for p in waived:
            print(f"warning: --force given, proceeding despite: {p}")
    if problems:
        for p in problems:
            print(f"error: {p}", file=sys.stderr)
        return 1

    if row["status"] == "rejected":
        # Not a refusal: a rejected round is out of the schedule but its bytes stay
        # addressable, and a rebuild is harmless. Worth saying out loud, because it
        # usually means the key came from the wrong place.
        print(f"note: {image} belongs to a rejected round -- rebuilding anyway")

    dest = WEB / image
    dest.parent.mkdir(parents=True, exist_ok=True)
    print(f"cutting {slug}.MP4 at {row['clip_ts_sec']}s -> {dest}")
    if not extract_clip({"slug": slug, "ts": row["clip_ts_sec"]}, dest):
        print(
            f"error: ffmpeg produced nothing usable from {slug}.MP4 at "
            f"{row['clip_ts_sec']}s. The corpus clip may itself be truncated",
            file=sys.stderr,
        )
        return 1

    if args.dry_run:
        print(f"ok: {dest} ({dest.stat().st_size} bytes). --dry-run, so not uploaded")
        return 0

    # Through clips.sh rather than wrangler directly, so a rebuild gets the same
    # retry loop and explicit content type as a full push.
    subprocess.run(
        [str(Path(__file__).parent / "clips.sh"), "push", str(dest)], check=True
    )
    print(f"ok: {image} is back. It serves from the bucket on the next request")
    return 0


if __name__ == "__main__":
    sys.exit(main())
