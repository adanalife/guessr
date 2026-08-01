#!/usr/bin/env python3
"""Validate a generated round set. Run after make_rounds.py.

Takes the directory holding rounds.json, answers.json and frames/, defaulting to
web/ (where a swapped-in set keeps its manifest; make_rounds.py runs this against
its staging directory, where the answers still sit alongside). Only a set that
passes gets swapped into web/, so these assertions are what stands between a bad
generation and the served game.

The check that matters is the aspect ratio: if the HUD crop ever stops applying,
every frame ships with the answer ("W71.606763 N42.822437") printed across the
bottom and the game is silently ruined. A 16:9 frame means the crop didn't run.

The second one is the split: rounds.json is served to the browser and must carry
no coordinates, and every round in it needs an answer to score against. A round
with no answer is unplayable (the API 404s it); a coordinate in the manifest hands
the answer to the player.
"""

import json
import struct
import sys
from pathlib import Path

WEB = Path(__file__).parent / "web"
ROUNDS_PER_GAME = 5  # must match web/index.html
UNCROPPED_ASPECT = 16 / 9  # 1.778 -- what a frame looks like with the HUD still on it
# Lower 48, generously bounded.
LAT_RANGE, LNG_RANGE = (24.0, 49.5), (-125.0, -66.0)


def dimensions(path: Path) -> tuple[int, int]:
    """Width and height, read straight out of the JPEG header.

    A frame is a JPEG and its size is in the first few hundred bytes, so this
    reads it rather than shelling out to ffprobe 300 times. ffmpeg is still
    what *extracts* the frames -- it's just no longer needed to validate them,
    which is the whole toolchain CI used to install.

    Any malformed file raises rather than returning a plausible size: a wrong
    answer here would pass an uncropped frame with the coordinates still on it.
    """
    with path.open("rb") as f:
        assert f.read(2) == b"\xff\xd8", f"not a JPEG: {path}"
        while True:
            header = f.read(4)
            assert len(header) == 4, f"ran off the end of {path} before its size"
            marker, size = struct.unpack(">HH", header)
            assert marker >> 8 == 0xFF, f"lost sync in {path} at {f.tell()}"
            # SOF0..SOF15 carry the dimensions; the three in that range that
            # aren't frame headers (DHT, JPG, DAC) do not.
            if 0xFFC0 <= marker <= 0xFFCF and marker not in (0xFFC4, 0xFFC8, 0xFFCC):
                # Segment body: 1 byte of precision, then height, then width.
                height, width = struct.unpack(">HH", f.read(5)[1:])
                return width, height
            f.seek(size - 2, 1)


def main() -> int:
    web = Path(sys.argv[1]) if len(sys.argv) > 1 else WEB
    rounds = json.loads((web / "rounds.json").read_text())
    assert rounds, "rounds.json is empty"
    assert len(rounds) >= ROUNDS_PER_GAME, (
        f"only {len(rounds)} rounds; a daily game needs {ROUNDS_PER_GAME}"
    )

    # A staged set keeps its answers alongside; a swapped-in one has them at the
    # repo root, outside the deployed directory. Neither is committed -- they are
    # the answers -- so CI checks the manifest alone and the cross-check below runs
    # where it can actually bite: on the machine that just generated a set, before
    # make_rounds.py swaps it in.
    answers = {}
    for candidate in (web / "answers.json", web.parent / "answers.json"):
        if candidate.is_file():
            answers = {a["image"]: a for a in json.loads(candidate.read_text())}
            break

    seen = set()
    for r in rounds:
        img = web / r["image"]
        assert img.exists() and img.stat().st_size > 0, f"missing frame: {r['image']}"
        assert r["image"] not in seen, f"duplicate round: {r['image']}"
        seen.add(r["image"])

        w, h = dimensions(img)
        aspect = w / h
        assert aspect > UNCROPPED_ASPECT + 0.05, (
            f"{r['image']} is {w}x{h} (aspect {aspect:.3f}) -- the HUD crop did not "
            f"apply, so the coordinates are still burned into the frame"
        )

        # The manifest is public. A coordinate in it is the answer, handed over.
        leaked = {"lat", "lng", "state", "filmed"} & r.keys()
        assert not leaked, (
            f"{r['image']}: rounds.json is served -- it must not carry {sorted(leaked)}"
        )

        assert r.get("median_km") is not None and r["median_km"] >= 0, (
            f"missing locatability score: {r}"
        )
        assert r.get("mean_cos"), f"missing distinctiveness score: {r}"

        if not answers:
            continue
        a = answers.get(r["image"])
        assert a, f"no answer for {r['image']} -- the API would 404 the round"
        assert LAT_RANGE[0] < a["lat"] < LAT_RANGE[1], f"lat out of range: {a}"
        assert LNG_RANGE[0] < a["lng"] < LNG_RANGE[1], f"lng out of range: {a}"
        assert a["state"] and a["filmed"], f"missing label: {a}"

    if not answers:
        print(
            f"ok: {len(rounds)} rounds, all frames HUD-cropped, no coordinates in "
            f"the served manifest"
        )
        print("    (no answers.json here, so the answer cross-check was skipped)")
        return 0

    states = {answers[r["image"]]["state"] for r in rounds}
    spread = sorted(r["median_km"] for r in rounds)
    print(f"ok: {len(rounds)} rounds, {len(states)} states, all frames HUD-cropped")
    print(
        f"    enough for {len(rounds) // ROUNDS_PER_GAME} days of dailies "
        f"before rounds start repeating"
    )
    # Worth eyeballing: the corpus tops out past 4000 km, so a max anywhere near
    # that means the locatability filter stopped biting.
    print(
        f"    locatability (median neighbour km): best {spread[0]:g}, "
        f"median {spread[len(spread) // 2]:g}, worst {spread[-1]:g}"
    )
    # The other half of the score: a low mean cosine distance means the frame has
    # near-identical twins elsewhere in the corpus, i.e. road a human can't place.
    cos = sorted(r["mean_cos"] for r in rounds)
    print(
        f"    distinctiveness (mean neighbour cosine): least {cos[0]:g}, "
        f"median {cos[len(cos) // 2]:g}, most {cos[-1]:g}"
    )
    return 0


if __name__ == "__main__":
    sys.exit(main())
