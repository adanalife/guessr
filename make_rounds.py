#!/usr/bin/env python3
"""Build a round set for the guessing game.

Samples clips from the dashcam corpus, extracts one frame each, and writes
web/rounds.json + web/frames/*.jpg. Everything downstream is static files.

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

QUERY = """
SELECT DISTINCT ON (v.id) v.slug, f.ts_sec, v.lat, v.lng, v.state, v.date_filmed
FROM videos v
JOIN frame_embeddings f ON f.video_id = v.id
WHERE v.lat <> 0 AND v.lng <> 0 AND v.state IS NOT NULL AND NOT v.flagged
  AND f.ts_sec > 15
ORDER BY v.id, random()
"""


def fetch_candidates(namespace: str) -> list[dict]:
    """Read corpus metadata out of the tripbot Postgres via kubectl exec."""
    out = subprocess.run(
        [
            "kubectl",
            "-n",
            namespace,
            "exec",
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
            "-c",
            QUERY,
        ],
        capture_output=True,
        text=True,
        check=True,
    ).stdout

    rows = []
    for line in out.splitlines():
        slug, ts, lat, lng, state, filmed = line.split("\t")
        rows.append(
            {
                "slug": slug,
                "ts": float(ts),
                "lat": float(lat),
                "lng": float(lng),
                "state": state,
                "filmed": filmed[:10],
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
    ap.add_argument("-n", "--count", type=int, default=60, help="rounds to generate")
    ap.add_argument("--width", type=int, default=1280, help="output frame width")
    ap.add_argument("--namespace", default="stage-1-data")
    ap.add_argument("--seed", type=int, default=None)
    args = ap.parse_args()

    random.seed(args.seed)
    frames = WEB / "frames"
    if frames.exists():
        shutil.rmtree(frames)
    frames.mkdir(parents=True)

    candidates = fetch_candidates(args.namespace)
    random.shuffle(candidates)
    print(f"{len(candidates)} clips eligible; extracting {args.count}")

    rounds = []
    for row in candidates:
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
            }
        )
        print(f"  {len(rounds):3d}/{args.count} {row['slug']} {row['state']}")

    (WEB / "rounds.json").write_text(json.dumps(rounds, indent=1))
    states = {r["state"] for r in rounds}
    print(f"\nwrote {len(rounds)} rounds across {len(states)} states")


if __name__ == "__main__":
    main()
