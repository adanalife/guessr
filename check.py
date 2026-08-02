#!/usr/bin/env python3
"""Validate a generated round set. Run after make_rounds.py.

Takes the directory holding rounds.json, answers.json and clips/, defaulting to
web/ (where a swapped-in set keeps its manifest; make_rounds.py runs this against
its staging directory, where the answers still sit alongside). Only a set that
passes gets swapped into web/, so these assertions are what stands between a bad
generation and the served game.

The check that matters is the aspect ratio: if the HUD crop ever stops applying,
every clip ships with the answer ("W71.606763 N42.822437") printed across the
bottom and the game is silently ruined. A 16:9 clip means the crop didn't run.

The second one is the split: rounds.json is served to the browser and must carry
no coordinates, and every round in it needs an answer to score against. A round
with no answer is unplayable (the API 404s it); a coordinate in the manifest hands
the answer to the player.

Two of the three things a round set is made of are absent in CI: the media is too
big to commit and the answers are the answers. So a directory with no clips/ at
all runs in manifest-only mode rather than failing, and the media assertions run
where the media exists -- on the machine that generated it, before make_rounds.py
swaps the set in, and again before `task clips:push` uploads it. A clips/ that
exists but is missing a file the manifest names is a real failure, not that mode.
"""

import json
import math
import struct
import sys
from collections import Counter
from pathlib import Path

WEB = Path(__file__).parent / "web"
ROUNDS_PER_GAME = 5  # must match web/index.html
UNCROPPED_ASPECT = 16 / 9  # 1.778 -- what a clip looks like with the HUD still on it
# Difficulty-band cutoffs in median_km, matching EASY_KM/HARD_KM in web/daily.js.
# The page rates every round against these, so a set whose scores all land on one
# side of them shows the same dots on every round and the rating means nothing.
EASY_KM, HARD_KM = 32.0, 120.0
# Two rounds closer together than this are the same answer wearing a different
# frame. Reported, never asserted: a clustered set is a worse set, not a broken
# one, and where the line sits is a judgement about the game rather than a fact
# about the data.
NEAR_KM = 5.0
# Lower 48, generously bounded.
LAT_RANGE, LNG_RANGE = (24.0, 49.5), (-125.0, -66.0)


def boxes(f, end: int):
    """Walk one level of ISO base media boxes, yielding (kind, start, stop).

    An mp4 is a tree of length-prefixed boxes and nothing else, so finding a
    field means walking to it. Reading the header rather than shelling out to
    ffprobe once per round is the same trade the JPEG reader made before it:
    ffmpeg is what *cuts* the clips, and keeping it off the validation path is
    what lets CI check a round set without installing a media toolchain.
    """
    while f.tell() + 8 <= end:
        start = f.tell()
        header = f.read(8)
        assert len(header) == 8, f"truncated box header at {start}"
        size, kind = struct.unpack(">I4s", header)
        if size == 1:
            # 64-bit size, in the eight bytes after the type.
            (size,) = struct.unpack(">Q", f.read(8))
        elif size == 0:
            size = end - start  # extends to the end of its parent
        assert size >= 8 and start + size <= end, f"bad {kind!r} box size {size}"
        yield kind, f.tell(), start + size
        f.seek(start + size)


def find(f, end: int, path: tuple[bytes, ...]):
    """Descend a chain of nested box types, returning (start, stop) of the last."""
    for depth, kind in enumerate(path):
        for found, start, stop in boxes(f, end):
            if found == kind:
                f.seek(start)
                end = stop
                break
        else:
            raise AssertionError(f"no {b'/'.join(path[: depth + 1]).decode()} box")
    return f.tell(), end


def dimensions(path: Path) -> tuple[int, int]:
    """Display width and height, read out of the video track's `tkhd` box.

    `tkhd` is the one that carries what the browser will lay the element out at,
    which is the number this file exists to check. Its width and height are the
    last eight bytes of the box body as 16.16 fixed point, in both versions of
    the box -- the version only changes the widths of the timestamp fields ahead
    of them, so counting back from the end reads both without branching.

    A file with more than one track would need the video one picked out; `-an`
    means there is exactly one, and the assert below says so rather than
    silently measuring whatever came first.

    Any malformed file raises rather than returning a plausible size: a wrong
    answer here would pass an uncropped clip with the coordinates still on it.
    """
    with path.open("rb") as f:
        end = path.stat().st_size
        assert end > 8, f"empty or truncated: {path}"
        f.seek(0)
        assert any(kind == b"moov" for kind, _, _ in boxes(f, end)), (
            f"no moov box -- not an mp4: {path}"
        )
        f.seek(0)
        moov_start, moov_end = find(f, end, (b"moov",))
        tracks = sum(1 for kind, _, _ in boxes(f, moov_end) if kind == b"trak")
        assert tracks == 1, f"expected one track, found {tracks}: {path}"

        f.seek(moov_start)
        tkhd_start, tkhd_end = find(f, moov_end, (b"trak", b"tkhd"))
        f.seek(tkhd_end - 8)
        width, height = struct.unpack(">II", f.read(8))
        # 16.16 fixed point. Rounded rather than truncated: a dimension stored as
        # 1279.99998 is 1280, and floor()ing it would report an aspect ratio a
        # hair off the real one on every clip.
        return round(width / 65536), round(height / 65536)


def km(a: dict, b: dict) -> float:
    """Great-circle distance between two answers, in kilometres."""
    lat1, lng1, lat2, lng2 = map(math.radians, (a["lat"], a["lng"], b["lat"], b["lng"]))
    return (
        2
        * 6371
        * math.asin(
            math.sqrt(
                math.sin((lat2 - lat1) / 2) ** 2
                + math.cos(lat1) * math.cos(lat2) * math.sin((lng2 - lng1) / 2) ** 2
            )
        )
    )


def clustering(answers: list[dict]) -> tuple[int, str, float]:
    """How much of a set is the same place twice: crowded rounds, and the top state.

    Nothing in the selection knows about spread -- make_rounds.py ranks each clip
    on its own merits -- so a road the corpus drove on many different days can
    supply a dozen rounds within sight of each other, and the states the van
    lived in crowd out the ones it merely drove through. Both play as a narrower
    game than the corpus actually holds: once a player learns the set leans one
    way, that lean is a free prior on every round.

    ponytail: O(n^2) over a few hundred rounds, which is milliseconds. Grid the
    points into cells if a set ever gets big enough to feel it.
    """
    crowded = set()
    for i, a in enumerate(answers):
        for j, b in enumerate(answers[i + 1 :], start=i + 1):
            if km(a, b) < NEAR_KM:
                crowded.update((i, j))
    state, n = Counter(a["state"] for a in answers).most_common(1)[0]
    return len(crowded), state, 100 * n / len(answers)


def band(median_km: float) -> int:
    """1 (easiest) to 3 (hardest) -- the same reading as difficulty() in daily.js."""
    return 1 if median_km < EASY_KM else 2 if median_km < HARD_KM else 3


def repeat_rate(pool: int, days: int = 90) -> tuple[int, float]:
    """Distinct rounds a daily player meets over `days`, and what share repeat.

    dailyRounds() in web/daily.js reshuffles the *whole* pool for every day and
    takes five. It does not deal the pool out into non-overlapping days, so
    "pool / 5 days before anything repeats" -- which this file used to print --
    describes a draw that was never implemented. Repeats begin in the first week
    or two at any pool size worth having; what a bigger pool buys is how *often*
    one comes round again, not whether.

    Each of the `5 * days` draws is uniform over the pool and independent, so the
    chance a given round is never drawn is (1 - 1/pool)**draws, i.e. e**-(d/pool)
    for a pool of any size. Expected distinct rounds follows, and everything else
    served was something the player had already seen.

    Checked against the real draw in test_check.py rather than trusted: this is
    the number that says whether a set is big enough, and being wrong about it in
    the reassuring direction is how the previous one lasted.
    """
    draws = ROUNDS_PER_GAME * days
    distinct = pool * (1 - math.exp(-draws / pool))
    return round(distinct), (draws - distinct) / draws


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

    # No clips/ at all is CI, which has the manifest and nothing else. A clips/
    # that exists and is missing something the manifest names is a broken set --
    # the distinction is deliberate, because "the media isn't here" must not be
    # the same sentence as "the media is here and wrong".
    media = (web / "clips").is_dir()

    seen = set()
    for r in rounds:
        clip = web / r["image"]
        assert r["image"] == f"clips/{Path(r['image']).name}", (
            f"round is not under clips/: {r['image']}"
        )
        assert r["image"] not in seen, f"duplicate round: {r['image']}"
        seen.add(r["image"])

        if media:
            assert clip.exists() and clip.stat().st_size > 0, (
                f"missing clip: {r['image']}"
            )
            w, h = dimensions(clip)
            aspect = w / h
            assert aspect > UNCROPPED_ASPECT + 0.05, (
                f"{r['image']} is {w}x{h} (aspect {aspect:.3f}) -- the HUD crop did "
                f"not apply, so the coordinates are still burned into the clip"
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

    # The cutoffs are the terciles of one particular set, so a regeneration that
    # skewed could empty a band -- which shows up in play only as every round
    # wearing identical dots. median_km stays in the served manifest, so this
    # bites whether or not the answers are alongside.
    bands = Counter(band(r["median_km"]) for r in rounds)
    for level in (1, 2, 3):
        assert bands[level], (
            f"no rounds in difficulty band {level} of 3 -- every game would show "
            f"the same rating, so the cutoffs ({EASY_KM:g} / {HARD_KM:g} km) want "
            f"recomputing for this set"
        )
    band_line = (
        f"    difficulty bands: {bands[1]} easy, {bands[2]} medium, {bands[3]} hard "
        f"(under {EASY_KM:g} / under {HARD_KM:g} km)"
    )

    cropped = "all clips HUD-cropped" if media else "manifest only"
    if media:
        mb = sum((web / r["image"]).stat().st_size for r in rounds) / 1e6
        size_line = (
            f"    {mb:.0f} MB of clips, {mb * 1e3 / len(rounds):.0f} KB per round "
            f"({mb * ROUNDS_PER_GAME / len(rounds):.1f} MB to play one game)"
        )

    if not answers:
        print(
            f"ok: {len(rounds)} rounds, {cropped}, no coordinates in "
            f"the served manifest"
        )
        print(band_line)
        if media:
            print(size_line)
        else:
            print("    (no clips/ here, so the HUD-crop check was skipped)")
        print("    (no answers.json here, so the answer cross-check was skipped)")
        return 0

    coords = [answers[r["image"]] for r in rounds]
    states = {a["state"] for a in coords}
    spread = sorted(r["median_km"] for r in rounds)
    print(f"ok: {len(rounds)} rounds, {len(states)} states, {cropped}")
    crowded, top_state, top_pct = clustering(coords)
    print(
        f"    spread: {crowded} of {len(rounds)} rounds sit within {NEAR_KM:g} km "
        f"of another round; {top_state} is {top_pct:.0f}% of the set"
    )
    distinct, repeats = repeat_rate(len(rounds))
    print(
        f"    a daily player meets {distinct} of them over 90 days, with "
        f"{repeats:.0%} of what they are served a round they have had before"
    )
    # Worth eyeballing: the corpus tops out past 4000 km, so a max anywhere near
    # that means the locatability filter stopped biting.
    print(
        f"    locatability (median neighbour km): best {spread[0]:g}, "
        f"median {spread[len(spread) // 2]:g}, worst {spread[-1]:g}"
    )
    print(band_line)
    # The other half of the score: a low mean cosine distance means the clip has
    # near-identical twins elsewhere in the corpus, i.e. road a human can't place.
    cos = sorted(r["mean_cos"] for r in rounds)
    print(
        f"    distinctiveness (mean neighbour cosine): least {cos[0]:g}, "
        f"median {cos[len(cos) // 2]:g}, most {cos[-1]:g}"
    )
    if media:
        print(size_line)
    return 0


if __name__ == "__main__":
    sys.exit(main())
