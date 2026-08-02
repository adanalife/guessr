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

Selecting a set costs seconds and encoding one costs tens of minutes, so
`--dry-run` stops between the two: it scores, selects, writes the manifest and
the answers, and reports what the set would look like without cutting a single
clip. That is the loop for tuning the knobs below, which otherwise can only be
compared by paying for two full generations.

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
import bisect
import hashlib
import json
import os
import shutil
import subprocess
import sys
from collections import Counter
from pathlib import Path

from check import NEAR_KM, km

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


def available(scored: list[dict]) -> list[dict]:
    """Drop candidates whose source clip isn't in the corpus, in one directory read.

    `videos` is derived from the corpus, so the two agreeing is the normal case
    and this drops nothing -- but when it does drop something, doing it here is
    what lets select() below return exactly the count it was asked for instead
    of discovering the gap one encode at a time.

    One listdir rather than a stat() per candidate: the corpus is an SMB mount,
    where a stat costs ~4ms and a pool of a couple of thousand would spend
    several seconds finding out what one directory read answers in ten
    milliseconds. An unmounted corpus raises here, which is the right moment --
    before anything under web/ has been touched.
    """
    present = set(os.listdir(CORPUS))
    return [r for r in scored if f"{r['slug']}.MP4" in present]


def rank(scored: list[dict], weight: float) -> list[dict]:
    """Order a scored pool on both signals at once, best round first.

    `scored` arrives ordered by median_km alone -- how tightly a clip's visual
    neighbours cluster in the real world -- with mean_cos used only as a floor.
    That ordering rewards frames it should be rejecting: empty blacktop the
    corpus drove on many days has a tight neighbour cluster and nothing a player
    can work with, and it survives the floor because the floor cuts a fixed
    slice of the pool rather than holding a quality bar.

    The two signals are close to independent (Spearman rho ~= 0.19 over a
    400-clip pool, see the README), so combining them is real information rather
    than the same measurement twice. Combined by *percentile* rather than by
    value: kilometres and cosine distances share no scale, so a weight applied
    to the raw numbers would mean something different for every pool.

    The default weight is 0.25 rather than an even split, from sweeping it on a
    2000-clip pool against the 300-round set that shipped (`--dry-run`, seed 7):

        weight   states  top state   locatability med/worst   distinctiveness
        shipped      23    CA  29%              84 / 230               0.0677
        0.00         25    WY  12%              67 / 177               0.0622
        0.25         26    CA  12%              72 / 313               0.0737
        0.50         30    CA  12%             107 / 1144              0.0858

    Half and half buys four more states and keeps climbing on distinctiveness,
    but it pays in rounds nobody can answer: a worst case of 1144 km is a clip
    whose visual neighbours average a thousand kilometres away, and the set goes
    from a third hard to nearly half hard. At 0.25 the set beats the shipped one
    on every axis at once, locatability included -- spreading a set out turns
    out to *improve* how locatable it is, because it stops the selection piling
    into a handful of well-driven clusters.
    """
    by_km = sorted(r["median_km"] for r in scored)
    by_cos = sorted(r["mean_cos"] for r in scored)

    def merit(r: dict) -> float:
        # Locatability is better when smaller, distinctiveness when larger.
        locatable = 1 - bisect.bisect_left(by_km, r["median_km"]) / len(scored)
        distinct = bisect.bisect_left(by_cos, r["mean_cos"]) / len(scored)
        return locatable * (1 - weight) + distinct * weight

    return sorted(scored, key=merit, reverse=True)


def select(
    ranked: list[dict], count: int, min_km: float, state_cap: int
) -> tuple[list[dict], int]:
    """Take the best `count` rounds that aren't the same place twice.

    Greedy down the ranked list, skipping any clip within `min_km` of one
    already taken, or from a state that has already filled its share. Returns
    the set and how many of it had to be backfilled without the spacing.

    Both constraints exist because nothing upstream knows about spread: every
    clip is scored alone, so the roads the van drove repeatedly score well
    repeatedly and a set comes out denser and narrower than the corpus behind
    it. Measured on the 300-round set that shipped: California is 33% of the
    rounds against 17% of the corpus, ten of the corpus's 32 states have no
    round at all, and 157 of 300 rounds sit within 5 km of another round --
    including fifteen consecutive minutes of one day's drive, served as five
    separate rounds. A player who notices the lean gets it as a free prior on
    every round afterwards.

    Backfilling rather than returning short: a crowded round still plays, and
    the round count is what the daily draw's repeat rate depends on. The state
    cap is *not* relaxed for the backfill -- it is the whole anti-skew guard,
    and a set that can only be filled by breaking it should come out short and
    say so.
    """
    chosen: list[dict] = []
    taken: set[str] = set()
    per_state: Counter = Counter()

    def take(spacing: float) -> None:
        for r in ranked:
            if len(chosen) >= count:
                return
            if r["slug"] in taken:
                continue
            if state_cap and per_state[r["state"]] >= state_cap:
                continue
            if spacing and any(km(r, c) < spacing for c in chosen):
                continue
            chosen.append(r)
            taken.add(r["slug"])
            per_state[r["state"]] += 1

    take(min_km)
    spread = len(chosen)
    take(0)
    return chosen, len(chosen) - spread


def extract_clip(
    row: dict,
    dest: Path,
    width: int,
    seconds: float,
    crf: int,
    fps: int,
    threads: int,
    niceness: int,
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
      It buys about 2% over `slow` for 3.5x the time, which is a bad trade
      anywhere the encode is on someone's critical path and a free one here.
    - `+faststart` puts the moov atom first, so the browser can start playing on
      the first bytes instead of waiting for the whole file.

    `nice` and `-threads` bound what the encode can take rather than trusting it
    to be modest. Three hundred of these is ~25 minutes of x264 that will use
    every core it is given, and the machines that would run it are machines with
    something else to do: a laptop being typed on, or -- if round generation ever
    moves to the minipc -- a node that is also playing out the live stream, where
    CPU contention is a known cause of a choppy broadcast. Half the cores and a
    positive nice value cost wall-clock and nothing else.
    """
    src = CORPUS / f"{row['slug']}.MP4"
    if not src.exists():
        return False

    vf = f"crop=iw:ih-{HUD_STRIP_PX}:0:0,scale={width}:-2,fps={fps}"
    proc = subprocess.run(
        [
            "nice",
            "-n",
            str(niceness),
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
            "-threads",
            str(threads),
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
        help="fraction of the scored pool to select from, best-scoring first. "
        "A quality window: everything below it is out regardless of how well it "
        "would have spread the set.",
    )
    ap.add_argument(
        "--distinctiveness",
        type=float,
        default=0.25,
        help="how much of a round's merit is having a visual signature of its "
        "own rather than being locatable, 0 to 1. See rank() for why 0.25 and "
        "not more; 0 reproduces the old locatability-only ordering.",
    )
    ap.add_argument(
        "--min-spacing",
        type=float,
        default=NEAR_KM,
        help="kilometres a round must sit from every other round in the set. "
        "0 turns the spacing off. See select() for what it is protecting "
        "against.",
    )
    ap.add_argument(
        "--state-cap",
        type=float,
        default=0.12,
        help="most of the set any one state may be, as a fraction. 0 turns the "
        "cap off, which lets the corpus's own skew through undamped.",
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
    ap.add_argument(
        "--dry-run",
        action="store_true",
        help="score and select, report what the set would look like, and cut "
        "nothing. Scoring a pool takes seconds and encoding it takes tens of "
        "minutes, so this is how the knobs above get tuned by trying them.",
    )
    ap.add_argument(
        "--threads",
        type=int,
        default=max(1, (os.cpu_count() or 2) // 2),
        help="cores x264 may use, half of them by default. See extract_clip: "
        "the encode is long enough to be worth bounding on a machine that has "
        "anything else to do.",
    )
    ap.add_argument(
        "--nice",
        type=int,
        default=10,
        help="scheduling niceness for the encode, so it loses every contest for "
        "a core rather than winning some of them",
    )
    ap.add_argument("--namespace", default="stage-1-data")
    ap.add_argument(
        "--seed",
        type=int,
        default=None,
        help="pin the database's pool draw, so the same seed rebuilds the same "
        "round set -- but only from an unchanged corpus, since new clips change "
        "what the same draw selects. Everything after the draw is deterministic. "
        "Without a seed every run draws a fresh pool.",
    )
    args = ap.parse_args()

    shutil.rmtree(STAGING, ignore_errors=True)
    clips = STAGING / "clips"
    # A dry run produces a manifest and its answers but no media, which is the
    # same shape CI sees -- so check.py reports on the set and skips the media
    # assertions on its own. Creating clips/ empty is what would turn that into
    # a wall of missing-clip failures.
    (STAGING if args.dry_run else clips).mkdir(parents=True)

    scored = available(
        score_candidates(args.namespace, args.pool, args.neighbours, args.seed)
    )
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
    eligible = rank(scored, args.distinctiveness)[:keep]
    print(
        f"scored {len(scored)} clips; selecting from the best {len(eligible)} "
        f"on locatability and distinctiveness together"
    )

    cap = max(1, int(args.count * args.state_cap)) if args.state_cap else 0
    eligible, backfilled = select(eligible, args.count, args.min_spacing, cap)
    if len(eligible) < args.count:
        print(
            f"only {len(eligible)} rounds fit under a {cap}-per-state cap -- "
            f"raise --pool, or --state-cap to let one state take more"
        )
    if backfilled:
        # Non-zero means the spacing pass ran out of well-spread candidates, so
        # check.py's spread line below will report these rather than zero.
        print(
            f"{backfilled} rounds are closer than {args.min_spacing:g} km to "
            f"another -- the pool ran out of spread before it ran out of rounds"
        )

    rounds, answers = [], []
    for row in eligible:
        name = f"{row['slug']}.mp4"
        if not args.dry_run and not extract_clip(
            row,
            clips / name,
            args.width,
            args.seconds,
            args.crf,
            args.fps,
            args.threads,
            args.nice,
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
    verb = "would stage" if args.dry_run else "staged"
    print(f"\n{verb} {len(rounds)} rounds across {len(states)} states")

    validate = subprocess.run(
        [sys.executable, str(Path(__file__).parent / "check.py"), str(STAGING)]
    )
    if validate.returncode != 0:
        print(
            f"\ncheck failed: {WEB} still holds the previous round set. "
            f"The rejected one is at {STAGING} to look at."
        )
        return 1

    if args.dry_run:
        print(
            f"\ndry run: nothing was cut and {WEB} is untouched. The manifest "
            f"and answers this run would have produced are in {STAGING}.\n"
            f"Rerun with the same --seed and no --dry-run to build this set for "
            f"real, or change the knobs and look again."
        )
        return 0

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
