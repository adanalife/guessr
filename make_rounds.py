#!/usr/bin/env python3
"""Build a round set for the guessing game.

Samples clips from the dashcam corpus, scores each one for how locatable it is,
cuts a few seconds out of the good ones, and writes web/rounds.json +
web/clips/*.mp4 -- the files the browser gets -- plus answers.json and
answers.sql outside web/, which hold the coordinates and never ship.

The split is the point: a manifest carrying the true lat/lng lets any player read
the answer out of devtools, so the coords go to D1 instead (`task
answers:{stage,prod}:push`) and functions/api/score.js is what turns a guess into
points. Nothing under web/ says where a clip was taken.

A run builds into web/.staging and only moves the result into place once check.py
passes on it. A run that dies on an unmounted corpus or an unreachable database
has to leave the current set exactly as it was rather than deleting it first.

web/clips/ is not committed -- a round set is ~125 MB and the repo is public, so
committing one would add that to history on every regeneration, permanently. The
manifest is committed and the media is uploaded separately (`task clips:push`),
which means the two can disagree: a deploy whose clips were never uploaded serves
a black pane per round. check.py catches that locally; smoke.sh catches it
against a real deployment.

Ground truth is the clip-level lat/lng in `videos`. The dashcam also burns
per-frame coords into the HUD, which would be a finer-grained truth if it were
OCR'd (video-pipeline's hud.py already reads that strip) -- but a clip covers
only a couple of miles, so clip coords are close enough to score against.
"""

import argparse
import hashlib
import json
import os
import random
import shutil
import subprocess
import sys
from pathlib import Path

CORPUS = Path("/Volumes/ADanaLife/dashcam/_opt/clips")
WEB = Path(__file__).parent / "web"
STAGING = WEB / ".staging"

# The HUD burns "49 MPH W71.606763 N42.822437" and the date across the bottom of
# every frame -- i.e. the answer. Crop it off. Measured against a 1920x1080 clip:
# the text baseline sits around y=1075, so 70px clears it with room to spare.
HUD_STRIP_PX = 70

# Scoring: a frame is a good round if visually similar frames come from nearby
# places. Take each candidate's nearest neighbours in SigLIP2 embedding space and
# measure how far their true locations sit from the candidate's. A tight cluster
# means the image carries real location signal; neighbours scattered across the
# continent mean it's anonymous interstate that could be anywhere.
#
# Same-day frames are excluded because consecutive clips are the next few minutes
# of the same road -- near-identical and a mile apart, so including them scores
# every clip as perfectly locatable. Date is a rough proxy for "the same drive".
#
# The same neighbours also give a second, near-independent signal: how visually
# distinctive the frame is, as the mean cosine distance to those neighbours. A
# frame whose neighbours are near-identical is a stretch of road the corpus drove
# many times on other days -- empty blacktop, fog, sky -- which scores as highly
# locatable (the neighbours really are all in one place) while a human player has
# nothing to work with. See the README for what that filter keeps and drops.
#
# Iterative scan matters: the day filter is applied during the HNSW scan, so
# without it a candidate whose neighbourhood is mostly same-day returns only a
# handful of rows (sometimes zero) and its median is noise. It is also ~5x faster
# here than letting the scan fall back to exhaustive.
SCORE_SQL = """
SET hnsw.ef_search = 100;
SET hnsw.iterative_scan = relaxed_order;
SET hnsw.max_scan_tuples = 40000;

WITH picked AS (
  SELECT id, slug, lat, lng, state, date_filmed
  FROM videos
  WHERE lat <> 0 AND lng <> 0 AND state IS NOT NULL AND NOT flagged
  ORDER BY random()
  LIMIT :pool
),
cand AS (
  SELECT DISTINCT ON (p.id)
         p.id AS vid, p.slug, p.lat, p.lng, p.state, p.date_filmed,
         f.embedding, f.ts_sec
  FROM picked p
  JOIN frame_embeddings f ON f.video_id = p.id
  WHERE f.ts_sec > 15
  ORDER BY p.id, random()
)
SELECT c.slug, c.ts_sec, c.lat, c.lng, c.state, c.date_filmed,
       nb.median_km, nb.n, nb.mean_cos
FROM cand c
CROSS JOIN LATERAL (
  SELECT percentile_cont(0.5) WITHIN GROUP (ORDER BY km) AS median_km,
         count(*) AS n,
         avg(cos_d) AS mean_cos
  FROM (
    SELECT 2*6371*asin(sqrt(
             power(sin(radians(v2.lat - c.lat)/2), 2) +
             cos(radians(c.lat))*cos(radians(v2.lat))*
             power(sin(radians(v2.lng - c.lng)/2), 2))) AS km,
           f2.embedding <=> c.embedding AS cos_d
    FROM frame_embeddings f2
    JOIN videos v2 ON v2.id = f2.video_id
    WHERE v2.lat <> 0
      AND v2.date_filmed::date <> c.date_filmed::date
    ORDER BY f2.embedding <=> c.embedding
    LIMIT :k
  ) neighbours
) nb
ORDER BY nb.median_km NULLS LAST;
"""


def pg_seed(seed: int) -> float:
    """Map an arbitrary integer onto the [-1.0, 1.0] double `setseed` accepts.

    Hashed rather than scaled so the small seeds a human actually types (1, 2,
    42) land far apart in the range instead of a rounding error from each other.
    sha256 rather than `hash()` because this has to agree with itself across
    processes, and Python salts string hashing per interpreter.
    """
    digest = hashlib.sha256(str(seed).encode()).digest()
    return int.from_bytes(digest[:8], "big") / 2**63 - 1.0


def score_sql(seed: int | None) -> str:
    """The scoring query, with its pool draw pinned when a seed is given.

    Postgres seeds its own PRNG per session, so seeding Python leaves the two
    `ORDER BY random()` clauses in SCORE_SQL free to draw a different pool every
    run. `setseed` pins them, and has to travel in the same session -- i.e. the
    same psql invocation -- as the query it applies to. Both clauses draw from
    that one session generator, so the second depends on the first; they sit in a
    single statement, so the order is fixed and the pair stays reproducible.

    Only against an unchanged corpus, though: adding a row to `videos` or
    `frame_embeddings` changes which clips the same sequence of random values
    picks out.
    """
    if seed is None:
        return SCORE_SQL
    return f"SELECT setseed({pg_seed(seed)!r});\n{SCORE_SQL}"


def score_candidates(
    namespace: str, pool: int, k: int, seed: int | None = None
) -> list[dict]:
    """Score a random pool of clips for locatability. Best (tightest) first."""
    out = subprocess.run(
        [
            "kubectl",
            "-n",
            namespace,
            "exec",
            "-i",
            "postgres-0",
            "--",
            "psql",
            "-U",
            "tripbot",
            "-d",
            "tripbot",
            "-At",
            "-F",
            "\t",
            # ON_ERROR_STOP because psql otherwise exits 0 on a SQL error, which
            # arrives here as an empty result and reads as "no clips matched".
            "-v",
            "ON_ERROR_STOP=1",
            "-v",
            f"pool={pool}",
            "-v",
            f"k={k}",
            "-f",
            "-",
        ],
        input=score_sql(seed),
        capture_output=True,
        text=True,
        check=True,
    ).stdout

    rows = []
    for line in out.splitlines():
        parts = line.split("\t")
        if len(parts) != 9:  # skip the SET / setseed acknowledgements
            continue
        slug, ts, lat, lng, state, filmed, median_km, n, mean_cos = parts
        if not median_km or int(n) < k:
            continue  # too few neighbours survived the filter to trust the median
        rows.append(
            {
                "slug": slug,
                "ts": float(ts),
                "lat": float(lat),
                "lng": float(lng),
                "state": state,
                "filmed": filmed[:10],
                "median_km": round(float(median_km), 1),
                "mean_cos": round(float(mean_cos), 4),
            }
        )
    return rows


def extract_clip(
    row: dict, dest: Path, width: int, seconds: float, crf: int, fps: int
) -> bool:
    """Cut one HUD-free clip. Returns False if the source isn't readable.

    A few seconds of motion rather than a still, because motion is the character
    of the source material and parallax is real information: a still flattens the
    depth cues that tell a hill from a backdrop.

    Encoding choices, all of them size-driven -- a round set is ~300 of these and
    none of them are in git:

    - 30fps, halved from the source's 60. The stream keeps 60 because that is its
      differentiator; a three-second loop of it is twice the bytes for nothing.
    - CRF 28. 26 is visibly better on shadow detail and 32 is visibly worse --
      distant signage goes to mush, and reading a sign after zooming in is the
      mechanic, so there is a floor here that a pure size argument would blow
      through.
    - `-an`: the corpus has audio, autoplay requires muted anyway, and it is
      bytes for something no player will ever hear.
    - `veryslow`: this runs once per round on a laptop, offline. The frames are
      the deliverable, so there is no reason to trade their size for encode time.
    - `+faststart` puts the moov atom first, so the browser can start playing on
      the first bytes instead of waiting for the whole file.
    """
    src = CORPUS / f"{row['slug']}.MP4"
    if not src.exists():
        return False

    vf = f"crop=iw:ih-{HUD_STRIP_PX}:0:0,scale={width}:-2,fps={fps}"
    proc = subprocess.run(
        [
            "ffmpeg",
            "-y",
            "-loglevel",
            "error",
            # Before -i, so ffmpeg seeks rather than decoding up to the mark.
            # Output-accurate regardless, since everything downstream is
            # re-encoded.
            "-ss",
            str(row["ts"]),
            "-t",
            str(seconds),
            "-i",
            str(src),
            "-vf",
            vf,
            "-an",
            "-c:v",
            "libx264",
            "-preset",
            "veryslow",
            "-crf",
            str(crf),
            # Baseline-compatible chroma and a leading moov atom: without
            # yuv420p some encodes come out 4:4:4, which Safari refuses to play
            # at all and which fails as a black pane rather than as an error.
            "-pix_fmt",
            "yuv420p",
            "-movflags",
            "+faststart",
            str(dest),
        ],
        capture_output=True,
        text=True,
    )
    return proc.returncode == 0 and dest.exists() and dest.stat().st_size > 0


def answers_sql(answers: list[dict]) -> str:
    """The seed script for D1's answers table.

    INSERT OR REPLACE rather than DELETE-then-INSERT: a regeneration replaces the
    rows it shares and leaves the rest, so there is no window where the table is
    empty and a push that dies halfway leaves every round still scorable. Old rows
    for retired frames cost nothing -- rounds.json is what decides which rounds are
    playable.
    """
    values = ",\n".join(
        "  ('{}', {}, {}, '{}', '{}')".format(
            a["image"].replace("'", "''"),
            a["lat"],
            a["lng"],
            a["state"].replace("'", "''"),
            a["filmed"].replace("'", "''"),
        )
        for a in answers
    )
    return (
        "CREATE TABLE IF NOT EXISTS answers (\n"
        "  image TEXT PRIMARY KEY,\n"
        "  lat REAL NOT NULL,\n"
        "  lng REAL NOT NULL,\n"
        "  state TEXT NOT NULL,\n"
        "  filmed TEXT NOT NULL\n"
        ");\n"
        "INSERT OR REPLACE INTO answers (image, lat, lng, state, filmed) VALUES\n"
        f"{values};\n"
    )


def write_answers(answers: list[dict], dest: Path) -> None:
    """Write the coords as JSON and as a D1 seed script, together.

    ponytail: two files holding the same data, which is normally a drift smell --
    but nothing writes one without the other, and they earn their keep separately.
    check.py asserts against the JSON; wrangler eats the SQL.
    """
    (dest / "answers.json").write_text(json.dumps(answers, indent=1) + "\n")
    (dest / "answers.sql").write_text(answers_sql(answers))


def swap_in(staging: Path, web: Path, root: Path | None = None) -> None:
    """Move a validated round set into place, keeping the old one until the last step.

    Renames rather than copies, so the served set is never half-written. A stale
    `clips.old` means a previous run died mid-swap; it is safe to clear.

    Checks the staged set is complete before touching anything under `web`: moving
    the live clips aside and only then discovering there is nothing to replace them
    with would take the game down, which is the failure this whole path exists to
    prevent.

    The answers land in `root` (the repo, gitignored) rather than under `web`, which
    is the whole deployed surface -- a coords file inside it would be fetchable.
    """
    root = root if root is not None else web.parent
    required = (
        staging / "rounds.json",
        staging / "answers.json",
        staging / "answers.sql",
    )
    if not (staging / "clips").is_dir() or not all(f.is_file() for f in required):
        raise FileNotFoundError(f"{staging} is not a complete round set; nothing moved")

    # Answers first: they sit outside web/, so getting them into place costs the
    # served game nothing if a later step fails.
    for name in ("answers.json", "answers.sql"):
        os.replace(staging / name, root / name)

    old = web / "clips.old"
    shutil.rmtree(old, ignore_errors=True)
    if (web / "clips").exists():
        (web / "clips").rename(old)
    (staging / "clips").rename(web / "clips")
    # ponytail: clips land before the manifest, so for a few milliseconds the served
    # manifest names clips from the previous set. Serving one 404 to whoever is
    # mid-request beats holding both sets on disk to make the pair truly atomic.
    os.replace(staging / "rounds.json", web / "rounds.json")
    shutil.rmtree(old, ignore_errors=True)
    shutil.rmtree(staging, ignore_errors=True)


def main() -> int:
    ap = argparse.ArgumentParser()
    ap.add_argument("-n", "--count", type=int, default=60, help="rounds to keep")
    ap.add_argument("--pool", type=int, default=400, help="clips to score")
    ap.add_argument("-k", "--neighbours", type=int, default=25)
    ap.add_argument(
        "--keep-fraction",
        type=float,
        default=0.5,
        help="fraction of the scored pool to sample from, best-scoring first. "
        "Sampling rather than taking the top N keeps the rounds varied.",
    )
    ap.add_argument(
        "--drop-generic",
        type=float,
        default=0.15,
        help="fraction of the scored pool to discard for having no visual "
        "signature of its own, lowest mean cosine distance first",
    )
    ap.add_argument("--width", type=int, default=1280, help="output clip width")
    ap.add_argument(
        "--seconds", type=float, default=3.0, help="length of each round's clip"
    )
    ap.add_argument(
        "--crf",
        type=int,
        default=28,
        help="x264 quality, lower is better and bigger. See extract_clip for why "
        "28 rather than the smaller numbers a size argument alone would pick.",
    )
    ap.add_argument("--fps", type=int, default=30, help="output frame rate")
    ap.add_argument("--namespace", default="stage-1-data")
    ap.add_argument(
        "--seed",
        type=int,
        default=None,
        help="pin both the database's pool draw and the Python shuffle, so the "
        "same seed rebuilds the same round set -- but only from an unchanged "
        "corpus, since new clips change what the same draw selects. Without a "
        "seed every run draws a fresh pool.",
    )
    args = ap.parse_args()

    random.seed(args.seed)
    shutil.rmtree(STAGING, ignore_errors=True)
    clips = STAGING / "clips"
    clips.mkdir(parents=True)

    scored = score_candidates(args.namespace, args.pool, args.neighbours, args.seed)
    # Cut the visually generic clips by percentile rather than an absolute cosine
    # distance, so the filter stays honest if the corpus or the embedding model
    # changes. ponytail: the pool is a few hundred rows, so sorting it twice is free.
    if scored and args.drop_generic:
        floor = sorted(r["mean_cos"] for r in scored)[
            int(len(scored) * args.drop_generic)
        ]
        before = len(scored)
        scored = [r for r in scored if r["mean_cos"] >= floor]
        print(
            f"dropped {before - len(scored)} clips with no visual signature of "
            f"their own (mean cosine distance < {floor:g})"
        )

    keep = max(args.count, int(len(scored) * args.keep_fraction))
    eligible = scored[:keep]
    cutoff = eligible[-1]["median_km"] if eligible else 0
    print(
        f"scored {len(scored)} clips; keeping the {len(eligible)} most locatable "
        f"(median neighbour distance <= {cutoff:g} km)"
    )

    random.shuffle(eligible)
    rounds, answers = [], []
    for row in eligible:
        if len(rounds) >= args.count:
            break
        name = f"{row['slug']}.mp4"
        if not extract_clip(
            row, clips / name, args.width, args.seconds, args.crf, args.fps
        ):
            print(f"  skip {row['slug']} (unreadable)")
            continue
        # `image` rather than `clip`: this string is the primary key of D1's
        # `answers` table and a column of `plays`, so renaming it is a migration
        # against live rows for no behavioural gain. The pre-launch regeneration
        # resets `plays` anyway -- that is the cheap moment to rename it, if ever.
        image = f"clips/{name}"
        # What the browser gets. The two scores stay -- median_km drives the
        # difficulty rating and the easy-to-hard ramp, and neither score says
        # anything about *where* the clip is.
        rounds.append(
            {
                "image": image,
                "median_km": row["median_km"],
                "mean_cos": row["mean_cos"],
            }
        )
        # What it does not.
        answers.append(
            {
                "image": image,
                "lat": row["lat"],
                "lng": row["lng"],
                "state": row["state"],
                "filmed": row["filmed"],
            }
        )
        print(
            f"  {len(rounds):3d}/{args.count} {row['slug']} "
            f"{row['state']} ({row['median_km']:g} km, cos {row['mean_cos']:g})"
        )

    # Trailing newline: rounds.json is committed, and end-of-file-fixer rewrites
    # it on every commit without one.
    (STAGING / "rounds.json").write_text(json.dumps(rounds, indent=1) + "\n")
    write_answers(answers, STAGING)
    states = {a["state"] for a in answers}
    print(f"\nstaged {len(rounds)} rounds across {len(states)} states")

    validate = subprocess.run(
        [sys.executable, str(Path(__file__).parent / "check.py"), str(STAGING)]
    )
    if validate.returncode != 0:
        print(
            f"\ncheck failed: {WEB} still holds the previous round set. "
            f"The rejected one is at {STAGING} to look at."
        )
        return 1

    swap_in(STAGING, WEB)
    size_mb = sum(f.stat().st_size for f in (WEB / "clips").iterdir()) / 1e6
    print(f"swapped into {WEB} ({size_mb:.0f} MB of clips)")
    # Two out-of-band pushes, and a deploy that runs without either looks green
    # while being unplayable: no clips is a black pane per round, no coords is
    # "unknown round" on every guess. Neither is inferable from the deploy.
    print(
        "\nnext, both of them, before deploying this set:\n"
        "  task clips:push    -- the media, to R2\n"
        "  task answers:stage:push (and answers:prod:push) -- the coords, to D1"
    )
    return 0


if __name__ == "__main__":
    sys.exit(main())
