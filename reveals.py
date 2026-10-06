#!/usr/bin/env python3
"""Cut the stills behind "here's where you guessed".

After a guess is scored, the page shows the corpus frame nearest the player's pin
beside the truth -- "you guessed here; this is what *here* looks like". That
needs a frame for anywhere a pin can land near a road the van drove, which is
the corpus thinned to a grid: one still per REVEAL_CELL_DEG cell, the moment
nearest the cell's centre. Written to web/reveals/<row>_<col>.jpg (pushed to R2
by `task reveals:push`) and reveals.sql (rows for D1, `task
reveals:{stage,prod}:push`).

Named by cell, never by clip. A round's image is `<slug>-<ms>.mp4`, and
/api/day hands those out before anyone guesses -- so a still named the same way
would let a script collect slug -> coordinate pairs through practice guesses and
read a daily's answer straight off its name. A cell index says only where the
still is, which the response carries anyway.

A still rather than a clip: the popup is a few hundred pixels wide, and ~8,000
of these as three-second mp4s would be ~4 GB against a few hundred MB.

Resumable. A still already on disk is not cut again, so a run that dies halfway
through a couple of hours of seeking picks up where it stopped -- and a still is
the same frame on every run, because the moment nearest a cell's centre only
moves when the corpus does.

Needs what make_rounds.py needs: the corpus mounted, and a route to the tripbot
Postgres (see its psql_invocation for the two ways in).
"""

import argparse
import subprocess
import sys
from pathlib import Path

from check import UNCROPPED_ASPECT, dimensions
from make_rounds import (
    CORPUS,
    CREDIT,
    HUD_STRIP_PX,
    MIN_CONFIDENCE,
    NICENESS,
    WATERMARK,
    WATERMARK_MARGIN_PX,
    WEB,
    psql_invocation,
)

# ~2.2 km of latitude, and less of longitude the further north. Measured against
# stage-1-data on 2026-09-22: 7,961 cells at 0.02, 3,160 at 0.05, 15,905 at 0.01.
# At 0.05 the nearest still can sit ~4 km from a pin that is right on a road it
# covers, which is no longer "here"; at 0.01 the grid is finer than a player can
# aim on a continental map, for twice the stills.
REVEAL_CELL_DEG = 0.02
# The popup shows these at ~320 px, and a retina screen at twice that; 960 leaves
# room to zoom before a sign goes to mush.
REVEAL_WIDTH = 960
# ffmpeg's JPEG scale, 2 best to 31 worst. 4 is ~90 KB at this width.
REVEAL_QUALITY = 4
REVEALS = WEB / "reveals"
SQL_OUT = Path(__file__).parent / "reveals.sql"
# D1 refuses a statement over 100 KB. A row here is ~45 bytes, so 500 of them
# keep each INSERT near a fifth of that.
ROWS_PER_STATEMENT = 500

# One row per cell, the moment nearest its centre. Held to the same moments a
# round may be cut from, for the same reasons (see make_rounds.py's SCORE_SQL):
# `source = 'ocr'` is a coordinate read off the frame itself, `ts_sec > 15` is
# what keeps out road the airing cut never shows, and the confidence gate drops a
# clip whose track disagrees with itself.
CELLS_SQL = f"""
SELECT DISTINCT ON (cy, cx) slug, ts_sec, lat, lng, cy, cx
FROM (
  SELECT v.slug, vc.ts_sec, vc.lat, vc.lng,
         floor(vc.lat / {REVEAL_CELL_DEG})::int AS cy,
         floor(vc.lng / {REVEAL_CELL_DEG})::int AS cx
  FROM video_coords vc
  JOIN videos v ON v.id = vc.video_id
  WHERE vc.source = 'ocr' AND vc.ts_sec > 15
    AND v.state IS NOT NULL AND NOT v.flagged
    AND v.coord_confidence >= {MIN_CONFIDENCE}
) m
ORDER BY cy, cx,
  power(lat - (cy + 0.5) * {REVEAL_CELL_DEG}, 2) +
  power(lng - (cx + 0.5) * {REVEAL_CELL_DEG}, 2),
  -- A tie on distance is two clips through the same spot. Settled by name so the
  -- pick, and so the still behind a cell's URL, is the same every run.
  slug, ts_sec;
"""


def parse_cells(out: str) -> list[dict]:
    """The cells carried by psql's tab-separated `out`.

    A line of any other width is psql talking rather than a row -- `SET`, a
    notice -- and is skipped, like make_rounds.parse_scored does.
    """
    cells = []
    for line in out.splitlines():
        parts = line.split("\t")
        if len(parts) != 6:
            continue
        slug, ts, lat, lng, cy, cx = parts
        cells.append(
            {
                "slug": slug,
                "ts": float(ts),
                "lat": float(lat),
                "lng": float(lng),
                "image": f"{int(cy)}_{int(cx)}.jpg",
            }
        )
    return cells


def cut_still(cell: dict, dest: Path) -> bool:
    """One HUD-cropped, watermarked frame. False if the source isn't readable
    or the crop didn't take -- a still with the HUD on it is the coordinates
    printed across the bottom, so it is dropped rather than published."""
    chain = (
        f"[0:v]crop=iw:ih-{HUD_STRIP_PX}:0:0,scale={REVEAL_WIDTH}:-2[cut];"
        f"[cut][1:v]overlay=W-w-{WATERMARK_MARGIN_PX}:H-h-{WATERMARK_MARGIN_PX}"
    )
    proc = subprocess.run(
        [
            "nice",
            "-n",
            str(NICENESS),
            "ffmpeg",
            "-y",
            "-loglevel",
            "error",
            "-ss",
            str(cell["ts"]),
            "-i",
            str(CORPUS / f"{cell['slug']}.MP4"),
            "-i",
            str(WATERMARK),
            "-filter_complex",
            chain,
            "-frames:v",
            "1",
            "-q:v",
            str(REVEAL_QUALITY),
            "-metadata",
            f"artist={CREDIT}",
            str(dest),
        ],
        capture_output=True,
        text=True,
    )
    if proc.returncode != 0 or not dest.exists():
        return False
    try:
        w, h = dimensions(dest)
    except AssertionError:
        dest.unlink()
        return False
    if w / h <= UNCROPPED_ASPECT + 0.05:
        dest.unlink()
        return False
    return True


def reveals_sql(cells: list[dict]) -> str:
    """The seed script for D1's reveals table, in statements D1 will accept.

    An upsert, like answers_sql: a regeneration rewrites the cells it shares and
    leaves the rest, so the table is never empty mid-push. Names are
    `<int>_<int>.jpg`, so there is nothing to quote.
    """
    statements = []
    for i in range(0, len(cells), ROWS_PER_STATEMENT):
        chunk = cells[i : i + ROWS_PER_STATEMENT]
        values = ",\n".join(
            f"  ('{c['image']}', {c['lat']}, {c['lng']})" for c in chunk
        )
        statements.append(
            "INSERT INTO reveals (image, lat, lng) VALUES\n"
            f"{values}\n"
            "ON CONFLICT (image) DO UPDATE SET\n"
            "  lat = excluded.lat,\n"
            "  lng = excluded.lng;\n"
        )
    return "".join(statements)


def main() -> int:
    ap = argparse.ArgumentParser(description=__doc__.split("\n\n")[0])
    ap.add_argument(
        "--namespace",
        default="stage-1-data",
        help="namespace holding postgres-0, as for make_rounds.py",
    )
    ap.add_argument(
        "--limit",
        type=int,
        default=0,
        help="cut at most this many new stills (0 = all), for trying a run out",
    )
    args = ap.parse_args()

    # psql_invocation carries make_rounds' own -v variables; this query names
    # none of them, and psql ignores a variable nothing reads.
    argv, env = psql_invocation(args.namespace, 0, 0, 0, 0.0)
    proc = subprocess.run(
        argv, input=CELLS_SQL, capture_output=True, text=True, env=env
    )
    if proc.returncode != 0:
        print(proc.stderr, file=sys.stderr)
        return 1
    cells = parse_cells(proc.stdout)
    if not cells:
        print("no cells came back -- is the corpus metadata there?", file=sys.stderr)
        return 1

    REVEALS.mkdir(parents=True, exist_ok=True)
    kept, cut, failed = [], 0, 0
    for cell in cells:
        dest = REVEALS / cell["image"]
        if not dest.exists():
            if args.limit and cut >= args.limit:
                continue
            if not cut_still(cell, dest):
                failed += 1
                continue
            cut += 1
            if cut % 100 == 0:
                print(f"  {cut} cut", flush=True)
        kept.append(cell)

    SQL_OUT.write_text(reveals_sql(kept))
    print(
        f"{len(cells)} cells, {cut} stills cut this run, {failed} unreadable; "
        f"{len(kept)} rows in {SQL_OUT.name}"
    )
    return 0


if __name__ == "__main__":
    sys.exit(main())
