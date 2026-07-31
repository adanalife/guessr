#!/usr/bin/env python3
"""Validate a generated round set. Run after make_rounds.py.

The check that matters is the aspect ratio: if the HUD crop ever stops applying,
every frame ships with the answer ("W71.606763 N42.822437") printed across the
bottom and the game is silently ruined. A 16:9 frame means the crop didn't run.
"""

import json
import subprocess
import sys
from pathlib import Path

WEB = Path(__file__).parent / "web"
UNCROPPED_ASPECT = 16 / 9  # 1.778 -- what a frame looks like with the HUD still on it
# Lower 48, generously bounded.
LAT_RANGE, LNG_RANGE = (24.0, 49.5), (-125.0, -66.0)


def dimensions(path: Path) -> tuple[int, int]:
    out = subprocess.run(
        [
            "ffprobe",
            "-v",
            "error",
            "-select_streams",
            "v:0",
            "-show_entries",
            "stream=width,height",
            "-of",
            "csv=p=0:s=x",
            str(path),
        ],
        capture_output=True,
        text=True,
        check=True,
    ).stdout.strip()
    w, h = out.split("x")
    return int(w), int(h)


def main() -> int:
    rounds = json.loads((WEB / "rounds.json").read_text())
    assert rounds, "rounds.json is empty"

    seen = set()
    for r in rounds:
        img = WEB / r["image"]
        assert img.exists() and img.stat().st_size > 0, f"missing frame: {r['image']}"
        assert r["image"] not in seen, f"duplicate round: {r['image']}"
        seen.add(r["image"])

        w, h = dimensions(img)
        aspect = w / h
        assert aspect > UNCROPPED_ASPECT + 0.05, (
            f"{r['image']} is {w}x{h} (aspect {aspect:.3f}) -- the HUD crop did not "
            f"apply, so the coordinates are still burned into the frame"
        )

        assert LAT_RANGE[0] < r["lat"] < LAT_RANGE[1], f"lat out of range: {r}"
        assert LNG_RANGE[0] < r["lng"] < LNG_RANGE[1], f"lng out of range: {r}"
        assert r["state"] and r["filmed"], f"missing label: {r}"

    states = {r["state"] for r in rounds}
    print(f"ok: {len(rounds)} rounds, {len(states)} states, all frames HUD-cropped")
    return 0


if __name__ == "__main__":
    sys.exit(main())
