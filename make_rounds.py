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

Ground truth is per-moment, from `video_coords`: the coordinate the dashcam
printed onto the frame the score describes, not the one coordinate `videos`
carries for the whole three-minute clip. The difference is not subtle -- the
clip-level answer sat a median 1,317 m from the road the player was actually
shown -- and it matters more now a round is a named street rather than a state.

Because a round plays for SECONDS and the van keeps moving, the answer is a
circle rather than a point: `radius_m` is how far it travels while the clip runs.
That is a statement about what the truth *is*, not leeway granted to the player;
the scoring curve cannot perceive a few hundred metres either way.
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

from check import MAX_RADIUS_M, MIN_RADIUS_M, NEAR_KM, dimensions, km

# The laptop mounts the corpus over SMB at this path; in the cluster it is an NFS
# mount at whatever path the pod spec picks. The default is the laptop's.
CORPUS = Path(os.environ.get("GUESSR_CORPUS", "/Volumes/ADanaLife/dashcam/_opt/clips"))
WEB = Path(__file__).parent / "web"
STAGING = WEB / ".staging"

# The HUD burns "49 MPH W71.606763 N42.822437" and the date across the bottom of
# every frame -- i.e. the answer. Crop it off. Measured against a 1920x1080 clip:
# the text baseline sits around y=1075, so 70px clears it with room to spare.
HUD_STRIP_PX = 70

# The encode. Settled by measurement (see extract_clip) and constants rather than
# flags: sweeping these means regenerating a set and looking at it, which is a
# day's work and a decision, not something a run gets to vary on its way past.
# The knobs that *are* swept -- pool, per-clip, distinctiveness, spacing, seed --
# are arguments, because --dry-run makes trying them cost seconds.
WIDTH = 1280
SECONDS = 3.0
CRF = 28
FPS = 30
# Bound what the encode may take rather than trusting it to be modest: ~300 of
# these is ~25 minutes of x264 that will use every core it is given, and the
# machine running it is a laptop being typed on.
THREADS = max(1, (os.cpu_count() or 2) // 2)
NICENESS = 10

# How much of a clip's coordinate track has to hold up before the clip may supply
# a round. Below this the coords stage's own reads disagreed with each other or
# implied a path nothing could have driven, so the answer would be confident and
# wrong -- which is worse than no round. 81% of the corpus clears it.
MIN_CONFIDENCE = 0.8

# What the two scores mean, why same-day frames are excluded, and why several
# moments are scored per clip: README, "How rounds are chosen". The four things
# that are about this query rather than about the scoring:
#
# - `hnsw.iterative_scan` is load-bearing, not tuning. The day filter is applied
#   during the scan, so without it a candidate whose neighbourhood is mostly
#   same-day comes back with a handful of rows, sometimes zero, and its median is
#   noise.
# - `:per_clip` moments per clip means one clip appears several times over.
#   Nothing downstream has to pick between them: select() skips a slug it has
#   taken, so a clip's first appearance going down the ranked list is its best
#   moment by the same merit every other round is chosen on. Dropping the extras
#   here in SQL would have to do it on median_km alone, which is the ordering
#   rank() exists to correct.
# - The score describes the round's *first* frame, not its middle: extract_clip
#   opens the cut on the scored timestamp (`-ss ts`).
# - `video_coords` answers the round, and it also measures the neighbours.
#   `videos.lat/lng` is one coordinate for three minutes of driving -- ~4.6 km of
#   travel, on top of its own ~1.7 km read error -- so using it put a median
#   1,317 m between the answer pin and the road the player was shown, and blurred
#   the neighbour distances that decide which rounds exist at all. Both are joined
#   per moment below. The grids do not line up (`frame_embeddings` samples every
#   5 s, the coords track every 2 s), so these are nearest-sample joins with the
#   window set to the track's own step rather than equality joins.
SCORE_SQL = """
SET hnsw.ef_search = 100;
SET hnsw.iterative_scan = relaxed_order;
SET hnsw.max_scan_tuples = 40000;

WITH picked AS (
  SELECT id, slug, state, date_filmed
  FROM videos
  WHERE state IS NOT NULL AND NOT flagged
    -- A clip whose track is not worth believing is not worth a round. This is
    -- strictly stronger than the old `lat <> 0` gate: a confidence means the
    -- coords stage read the clip and its reads agreed with each other.
    AND coord_confidence >= :min_conf
  ORDER BY random()
  LIMIT :pool
),
cand AS (
  SELECT p.id AS vid, p.slug, p.state, p.date_filmed,
         f.embedding, f.ts_sec, f.source_ts_sec, f.lat, f.lng, f.travel_m
  FROM picked p
  CROSS JOIN LATERAL (
    SELECT fe.embedding, fe.ts_sec, here.lat, here.lng,
           -- This round's moment on the source timeline, which is its stable
           -- identity: `here` is up to a second away, so its own source_ts_sec
           -- names a different moment. What travels is the *offset* between the
           -- two timelines -- zero for the 97% of clips that are not trims --
           -- applied to the frame the round is actually cut at.
           fe.ts_sec + (here.source_ts_sec - here.ts_sec) AS source_ts_sec,
           -- How far the van moves over the seconds the round plays. The answer
           -- is that stretch of road rather than the point it starts at, and this
           -- is what radius_m ends up describing.
           2*6371000*asin(sqrt(
             power(sin(radians(COALESCE(ahead.lat, here.lat) - here.lat)/2), 2) +
             cos(radians(here.lat))*cos(radians(COALESCE(ahead.lat, here.lat)))*
             power(sin(radians(COALESCE(ahead.lng, here.lng) - here.lng)/2), 2)
           )) AS travel_m
    FROM frame_embeddings fe
    -- The coordinate this round is answered with, and it has to be one the
    -- dashcam actually printed on the frame: `source = 'ocr'` excludes the rows
    -- interpolation filled in. 78% of sampled moments have one within a second,
    -- which is far more candidate moments than :per_clip needs.
    --
    -- The BETWEEN is not an optimisation. It bounds the search to the track's own
    -- 2 s step, so a moment sitting inside a gap in the track drops out of
    -- contention entirely instead of being answered from the far side of the gap.
    CROSS JOIN LATERAL (
      SELECT lat, lng, ts_sec, source_ts_sec
      FROM video_coords
      WHERE video_id = fe.video_id AND source = 'ocr'
        AND ts_sec BETWEEN fe.ts_sec - 1.5 AND fe.ts_sec + 1.5
      ORDER BY abs(ts_sec - fe.ts_sec)
      LIMIT 1
    ) here
    -- Where the van has got to by the time the round stops playing. LEFT, because
    -- a moment near the end of a clip has nothing ahead of it and is still a
    -- perfectly good round -- travel_m comes out 0 and the caller floors it.
    LEFT JOIN LATERAL (
      SELECT lat, lng
      FROM video_coords
      WHERE video_id = fe.video_id AND ts_sec IS NOT NULL
        AND ts_sec BETWEEN fe.ts_sec + :clip_secs - 2.5
                       AND fe.ts_sec + :clip_secs + 2.5
      ORDER BY abs(ts_sec - (fe.ts_sec + :clip_secs))
      LIMIT 1
    ) ahead ON true
    WHERE fe.video_id = p.id AND fe.ts_sec > 15
    ORDER BY random()
    LIMIT :per_clip
  ) f
)
SELECT c.slug, c.ts_sec, c.source_ts_sec, c.lat, c.lng, c.travel_m,
       c.state, c.date_filmed, nb.median_km, nb.n, nb.mean_cos
FROM cand c
CROSS JOIN LATERAL (
  SELECT percentile_cont(0.5) WITHIN GROUP (ORDER BY nn.km) AS median_km,
         count(*) AS n,
         avg(nn.cos_d) AS mean_cos
  FROM (
    -- Distance from the candidate's real position to each neighbour's. The
    -- neighbour's own per-moment coordinate where it has one, its clip's
    -- otherwise: about a fifth of the corpus has no trusted track, and a median
    -- over :k neighbours barely moves when a few of them are clip-level, while
    -- dropping them thins the neighbourhood the HNSW scan is walking.
    SELECT n.cos_d,
           2*6371*asin(sqrt(
             power(sin(radians(COALESCE(nc.lat, nv.lat) - c.lat)/2), 2) +
             cos(radians(c.lat))*cos(radians(COALESCE(nc.lat, nv.lat)))*
             power(sin(radians(COALESCE(nc.lng, nv.lng) - c.lng)/2), 2)
           )) AS km
    -- The k nearest first, coords joined after. Joining them inside this
    -- subquery would evaluate a lateral per row the scan touches -- thousands --
    -- rather than :k times.
    FROM (
      SELECT f2.video_id, f2.ts_sec, f2.embedding <=> c.embedding AS cos_d
      FROM frame_embeddings f2
      JOIN videos vf ON vf.id = f2.video_id
      WHERE vf.lat <> 0
        AND vf.date_filmed::date <> c.date_filmed::date
      ORDER BY f2.embedding <=> c.embedding
      LIMIT :k
    ) n
    JOIN videos nv ON nv.id = n.video_id
    LEFT JOIN LATERAL (
      SELECT lat, lng
      FROM video_coords
      WHERE video_id = n.video_id AND ts_sec IS NOT NULL
        AND ts_sec BETWEEN n.ts_sec - 1.5 AND n.ts_sec + 1.5
      ORDER BY abs(ts_sec - n.ts_sec)
      LIMIT 1
    ) nc ON true
  ) nn
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
    picks out. `--per-clip` does the same, for the same reason -- it changes how
    many values the frame draw consumes, so a seed reproduces a set only alongside
    the depth it was generated at.
    """
    if seed is None:
        return SCORE_SQL
    return f"SELECT setseed({pg_seed(seed)!r});\n{SCORE_SQL}"


def psql_invocation(
    namespace: str, pool: int, k: int, per_clip: int, min_conf: float
) -> tuple[list[str], dict[str, str]]:
    """How to run the scoring query: straight at Postgres, or via kubectl exec.

    `DATABASE_HOST` is the switch, because it is the thing that is only true in
    one of the two places. From the laptop there is no route to the database at
    all -- it lives in the cluster with no ingress -- so the only way in is to
    exec a psql that is already inside. A process running *in* the cluster
    reaches the Service directly and has no business shelling out to kubectl for
    it, nor the RBAC to.

    Names follow the project-wide DATABASE_* vars that tripbot's Go and
    video-pipeline's db.py already read, so an in-cluster deployment configures
    this the same way it configures everything else. The defaults are the laptop
    path, so an unset environment takes the kubectl route.
    """
    query = [
        "psql",
        "-U",
        os.environ.get("DATABASE_USER", "tripbot"),
        "-d",
        os.environ.get("DATABASE_DB", "tripbot"),
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
        "-v",
        f"per_clip={per_clip}",
        "-v",
        f"min_conf={min_conf}",
        # The encode's own clip length, so the query can measure how far the van
        # travels over exactly the seconds a player will watch.
        "-v",
        f"clip_secs={SECONDS}",
        "-f",
        "-",
    ]
    host = os.environ.get("DATABASE_HOST")
    if not host:
        exec_argv = ["kubectl", "-n", namespace, "exec", "-i", "postgres-0", "--"]
        return [*exec_argv, *query], dict(os.environ)

    # PG* is how libpq takes a host and a password. Only the local psql reads
    # them, which is why they belong to this branch: on the kubectl path the psql
    # that matters is inside the pod and connects over its own loopback.
    return query, {
        **os.environ,
        "PGHOST": host,
        "PGPORT": os.environ.get("DATABASE_PORT", "5432"),
        "PGPASSWORD": os.environ.get("DATABASE_PASS", ""),
    }


def score_candidates(
    namespace: str,
    pool: int,
    k: int,
    per_clip: int = 4,
    seed: int | None = None,
    min_conf: float = MIN_CONFIDENCE,
    max_radius_m: float = MAX_RADIUS_M,
) -> list[dict]:
    """Score a random pool of clips for locatability. Best (tightest) first.

    Returns up to `per_clip` candidate moments per clip, so one clip can appear
    several times over. select() keeps the best of them.

    Each row carries the coordinate the dashcam printed on that frame, the offset
    into the original recording that identifies it (see the per-moment-data-keyed-
    to-source decision -- a re-trim shifts clip offsets and leaves this one
    alone), and the radius the answer needs because the van keeps moving while the
    round plays.
    """
    argv, env = psql_invocation(namespace, pool, k, per_clip, min_conf)
    try:
        out = subprocess.run(
            argv,
            env=env,
            input=score_sql(seed),
            capture_output=True,
            text=True,
            check=True,
        ).stdout
    except FileNotFoundError:
        # The two routes need different binaries, and an unattended run should say
        # which one is missing rather than raise a traceback out of subprocess.
        sys.exit(
            f"{argv[0]}: not found. Scoring reaches Postgres either by exec'ing "
            "into the pod, which needs kubectl, or straight over the network when "
            "DATABASE_HOST is set, which needs a psql client on PATH."
        )

    rows = []
    for line in out.splitlines():
        parts = line.split("\t")
        if len(parts) != 11:  # skip the SET / setseed acknowledgements
            continue
        (
            slug,
            ts,
            source_ts,
            lat,
            lng,
            travel_m,
            state,
            filmed,
            median_km,
            n,
            mean_cos,
        ) = parts
        if not median_km or int(n) < k:
            continue  # too few neighbours survived the filter to trust the median
        # A round whose circle would be wider than the ceiling is dropped rather
        # than widened: see MAX_RADIUS_M. Floored the other way, because the
        # coordinate is not exact even where the van was stopped.
        radius_m = max(float(travel_m), MIN_RADIUS_M)
        if radius_m > max_radius_m:
            continue
        rows.append(
            {
                "slug": slug,
                "ts": float(ts),
                "source_ts": float(source_ts),
                "lat": float(lat),
                "lng": float(lng),
                "radius_m": round(radius_m, 1),
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

    What the two signals are and why both: README, "The second signal:
    distinctiveness". Combined by *percentile* rather than by value, because
    kilometres and cosine distances share no scale -- a weight applied to the raw
    numbers would mean something different for every pool.

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


def extract_clip(row: dict, dest: Path) -> bool:
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

    Half the cores at a positive nice value cost wall-clock and nothing else, and
    keep 25 minutes of x264 from taking the laptop it is running on.
    """
    src = CORPUS / f"{row['slug']}.MP4"
    vf = f"crop=iw:ih-{HUD_STRIP_PX}:0:0,scale={WIDTH}:-2,fps={FPS}"
    # A frame's timestamp can be the clip's last one, and a window starting there
    # holds nothing: ffmpeg writes a valid, empty container, exits 0, and leaves a
    # few hundred bytes on disk, so return code and file size both say it worked.
    # The emptiness only surfaces in check.py, at the end of a run that spent
    # twenty-five minutes encoding everything else. Cut the tail instead.
    for ts in (row["ts"], max(0.0, row["ts"] - SECONDS)):
        proc = subprocess.run(
            [
                "nice",
                "-n",
                str(NICENESS),
                "ffmpeg",
                "-y",
                "-loglevel",
                "error",
                # Before -i, so ffmpeg seeks rather than decoding up to the mark.
                # Output-accurate regardless, since everything downstream is
                # re-encoded.
                "-ss",
                str(ts),
                "-t",
                str(SECONDS),
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
                str(CRF),
                # Baseline-compatible chroma and a leading moov atom: without
                # yuv420p some encodes come out 4:4:4, which Safari refuses to play
                # at all and which fails as a black pane rather than as an error.
                "-pix_fmt",
                "yuv420p",
                "-movflags",
                "+faststart",
                "-threads",
                str(THREADS),
                str(dest),
            ],
            capture_output=True,
            text=True,
        )
        if proc.returncode != 0 or not dest.exists():
            return False
        try:
            dimensions(dest)
        except AssertionError:
            continue  # no video track: the seek landed past the last frame
        return True
    return False


def clip_name(row: dict) -> str:
    """The filename for a round: its source clip, and the moment within it.

    The moment is in the name because a clip supplies several candidate moments
    and only one becomes a round -- but mostly because two things downstream need
    a name that cannot mean two different sets of bytes:

    - `task rounds:rebuild` re-cuts a clip that was deleted or corrupted, and it
      can only land the result back at the same URL if the URL says which moment
      it was.
    - a long `immutable` cache header is only safe if a regeneration cannot put
      different footage at a name someone already has cached. Under the old
      `<slug>.mp4` it could, which is why web/clips/ has no _headers rule.

    Milliseconds as an integer, so nothing depends on how a float formats.

    ponytail: the name is not a content hash, so a libx264 upgrade changes the
    bytes behind a stable URL. It changes them to the same three seconds of road,
    which is the whole of what the URL promises.
    """
    return f"{row['slug']}-{round(row['ts'] * 1000):06d}.mp4"


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
        "--per-clip",
        type=int,
        default=4,
        help="candidate moments to score per clip, keeping the best of them. A "
        "clip's frames vary more in quality than clips do, so 1 hands the round "
        "whichever moment it drew. See SCORE_SQL.",
    )
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
        "not more; 0 ranks on locatability alone.",
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
    ap.add_argument(
        "--min-confidence",
        type=float,
        default=MIN_CONFIDENCE,
        help="how far a clip's coordinate track has to be trusted before it may "
        "supply a round, 0 to 1. 0 lets every clip through, including the ones "
        "whose reads contradicted each other. See MIN_CONFIDENCE.",
    )
    ap.add_argument(
        "--max-radius",
        type=float,
        default=MAX_RADIUS_M,
        help="metres of road a round may cover before it is dropped rather than "
        "answered with a wider circle. See MAX_RADIUS_M.",
    )
    ap.add_argument(
        "--dry-run",
        action="store_true",
        help="score and select, report what the set would look like, and cut "
        "nothing. Scoring a pool takes seconds and encoding it takes tens of "
        "minutes, so this is how the knobs above get tuned by trying them.",
    )
    ap.add_argument(
        "--namespace",
        default="stage-1-data",
        help="namespace holding postgres-0, for the kubectl exec route into the "
        "database. Ignored when DATABASE_HOST is set, which is how anything "
        "running inside the cluster reaches Postgres instead.",
    )
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
        score_candidates(
            args.namespace,
            args.pool,
            args.neighbours,
            args.per_clip,
            args.seed,
            args.min_confidence,
            args.max_radius,
        )
    )
    # Cut the visually generic moments by percentile rather than an absolute cosine
    # distance, so the filter stays honest if the corpus or the embedding model
    # changes. ponytail: the pool is a few hundred rows, so sorting it twice is free.
    #
    # A moment rather than a clip is the unit here and in --keep-fraction below,
    # because --per-clip scores several of each: a clip stays in contention while
    # any one of its moments clears the bar, and loses only the moments that don't.
    if scored and args.drop_generic:
        floor = sorted(r["mean_cos"] for r in scored)[
            int(len(scored) * args.drop_generic)
        ]
        before = len(scored)
        scored = [r for r in scored if r["mean_cos"] >= floor]
        print(
            f"dropped {before - len(scored)} moments with no visual signature of "
            f"their own (mean cosine distance < {floor:g})"
        )

    keep = max(args.count, int(len(scored) * args.keep_fraction))
    eligible = rank(scored, args.distinctiveness)[:keep]
    print(
        f"scored {len(scored)} moments across {len({r['slug'] for r in scored})} "
        f"clips; selecting from the best {len(eligible)} on locatability and "
        f"distinctiveness together"
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
        name = clip_name(row)
        if not args.dry_run and not extract_clip(row, clips / name):
            print(f"  skip {row['slug']} (unreadable)")
            continue
        # `image` rather than `clip`: this string is the primary key of D1's
        # `answers` table and a column of `plays`, so renaming it is a migration
        # against live rows for no behavioural gain. A regeneration that resets
        # `plays` is the cheap moment to rename it, if ever.
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
        # What it does not. The first five go to D1; the rest stay in
        # answers.json, which is the record of how a round was made.
        #
        # ponytail: `answers` in D1 keeps its five columns for now. Adding one
        # means an ALTER against two live databases, and nothing consumes these
        # four yet -- the reveal circle, `rounds:rebuild` and a coords report all
        # want them, and all three land with the D1 schema that carries the round
        # pool. See vault/guessr/round-pipeline-design.md.
        answers.append(
            {
                "image": image,
                "lat": row["lat"],
                "lng": row["lng"],
                "state": row["state"],
                "filmed": row["filmed"],
                "slug": row["slug"],
                # The stable identity of the moment: an offset into the original
                # recording, which nothing ever re-cuts. `clip_ts_sec` is what
                # ffmpeg was actually given, and the two differ only for the 122
                # trimmed clips once a trim point is corrected.
                "source_ts_sec": row["source_ts"],
                "clip_ts_sec": row["ts"],
                # How wide the answer really is, in metres.
                "radius_m": row["radius_m"],
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
