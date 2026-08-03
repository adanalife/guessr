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
import subprocess
import sys
from collections import Counter
from pathlib import Path

WEB = Path(__file__).parent / "web"
ROUNDS_PER_GAME = 5  # must match web/index.html
UNCROPPED_ASPECT = 16 / 9  # 1.778 -- what a clip looks like with the HUD still on it
# Difficulty-band cutoffs in median_km, the terciles of the shipped round set.
# A set whose scores all land on one side of them has no spread for the
# easy-to-hard ramp to order, so every game plays at one difficulty.
EASY_KM, HARD_KM = 32.0, 120.0
# Two rounds closer together than this are the same answer wearing a different
# frame. Reported, never asserted: a clustered set is a worse set, not a broken
# one, and where the line sits is a judgement about the game rather than a fact
# about the data.
NEAR_KM = 5.0
# Lower 48, generously bounded.
LAT_RANGE, LNG_RANGE = (24.0, 49.5), (-125.0, -66.0)


def dimensions(path: Path) -> tuple[int, int]:
    """Width and height of a clip's one video stream.

    Every caller is already on a machine with ffmpeg, because ffmpeg is what cut
    the clip: this runs from the media branch below, and from make_rounds.py
    immediately after an encode. CI is the case that would want a dependency-free
    reader, and CI never reaches here -- the clips are gitignored, so check.py
    runs there in manifest-only mode.

    Anything that isn't a readable single-video-stream file raises rather than
    returning a plausible size, because a wrong answer here would pass an
    uncropped clip with the coordinates still burned into it. An empty container
    -- what a seek past the last frame produces, which ffmpeg writes and exits 0
    on -- carries no video stream, so it fails here rather than downstream.
    """
    proc = subprocess.run(
        [
            "ffprobe",
            "-v",
            "error",
            # Every video stream, not just the first: one is what an encode with
            # a single input produces, and anything else is ambiguous enough
            # that measuring one of them is a guess.
            "-select_streams",
            "v",
            "-show_entries",
            "stream=width,height",
            "-of",
            "csv=p=0",
            str(path),
        ],
        capture_output=True,
        text=True,
    )
    streams = proc.stdout.split()
    assert len(streams) == 1, (
        f"expected one video stream, found {len(streams)}: {path}"
        + (f" -- {proc.stderr.strip()}" if proc.stderr.strip() else "")
    )
    width, height = (int(n) for n in streams[0].split(","))
    return width, height


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
    """1 (easiest) to 3 (hardest)."""
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
    # skewed could empty a band -- which shows up in play only as a flat game,
    # every round about as hard as the last. median_km stays in the served
    # manifest, so this bites whether or not the answers are alongside.
    bands = Counter(band(r["median_km"]) for r in rounds)
    for level in (1, 2, 3):
        assert bands[level], (
            f"no rounds in difficulty band {level} of 3 -- the ramp has nothing "
            f"to order, so the cutoffs ({EASY_KM:g} / {HARD_KM:g} km) want "
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
