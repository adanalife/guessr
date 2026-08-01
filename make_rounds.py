#!/usr/bin/env python3
"""Build a round set for the guessing game.

Samples clips from the dashcam corpus, scores each one for how locatable it is,
extracts a frame from the good ones, and writes web/rounds.json +
web/frames/*.jpg. Everything downstream is static files.

Ground truth is the clip-level lat/lng in `videos`. The dashcam also burns
per-frame coords into the HUD, which would be a finer-grained truth if it were
OCR'd (video-pipeline's hud.py already reads that strip) -- but a clip covers
only a couple of miles, so clip coords are close enough to score against.
"""

import argparse
import json
import random
import shutil
import subprocess
from pathlib import Path

CORPUS = Path("/Volumes/ADanaLife/dashcam/_opt/clips")
WEB = Path(__file__).parent / "web"

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


def score_candidates(namespace: str, pool: int, k: int) -> list[dict]:
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
        input=SCORE_SQL,
        capture_output=True,
        text=True,
        check=True,
    ).stdout

    rows = []
    for line in out.splitlines():
        parts = line.split("\t")
        if len(parts) != 9:  # skip the SET acknowledgements
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


def extract_frame(row: dict, dest: Path, width: int) -> bool:
    """Grab one HUD-free frame. Returns False if the clip isn't readable."""
    src = CORPUS / f"{row['slug']}.MP4"
    if not src.exists():
        return False

    vf = f"crop=iw:ih-{HUD_STRIP_PX}:0:0,scale={width}:-2"
    proc = subprocess.run(
        [
            "ffmpeg",
            "-y",
            "-loglevel",
            "error",
            "-ss",
            str(row["ts"]),
            "-i",
            str(src),
            "-frames:v",
            "1",
            "-vf",
            vf,
            "-q:v",
            "3",
            str(dest),
        ],
        capture_output=True,
        text=True,
    )
    return proc.returncode == 0 and dest.exists() and dest.stat().st_size > 0


def main() -> None:
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
    ap.add_argument("--width", type=int, default=1280, help="output frame width")
    ap.add_argument("--namespace", default="stage-1-data")
    ap.add_argument("--seed", type=int, default=None)
    args = ap.parse_args()

    random.seed(args.seed)
    frames = WEB / "frames"
    if frames.exists():
        shutil.rmtree(frames)
    frames.mkdir(parents=True)

    scored = score_candidates(args.namespace, args.pool, args.neighbours)
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
    rounds = []
    for row in eligible:
        if len(rounds) >= args.count:
            break
        name = f"{row['slug']}.jpg"
        if not extract_frame(row, frames / name, args.width):
            print(f"  skip {row['slug']} (unreadable)")
            continue
        rounds.append(
            {
                "image": f"frames/{name}",
                "lat": row["lat"],
                "lng": row["lng"],
                "state": row["state"],
                "filmed": row["filmed"],
                "median_km": row["median_km"],
                "mean_cos": row["mean_cos"],
            }
        )
        print(
            f"  {len(rounds):3d}/{args.count} {row['slug']} "
            f"{row['state']} ({row['median_km']:g} km, cos {row['mean_cos']:g})"
        )

    (WEB / "rounds.json").write_text(json.dumps(rounds, indent=1))
    states = {r["state"] for r in rounds}
    print(f"\nwrote {len(rounds)} rounds across {len(states)} states")


if __name__ == "__main__":
    main()
