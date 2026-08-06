#!/usr/bin/env python3
"""Validate a generated round set. Run after make_rounds.py.

Takes the directory holding clips/, defaulting to web/. The manifest and the
answers are looked up beside it or one level up, because a staged set keeps all
of it together while a swapped-in one has clips/ under web/ and both JSON files
at the repo root, outside the deployed directory.

**This runs on the machine that generates a set, and nowhere else.** It used to
run in CI too, over a committed web/rounds.json -- the round set is data in D1
now, so there is nothing in the repo for CI to check. That is a real loss of a
belt-and-braces guard and it is why the two assertions below that catch a ruined
set both run before anything is published, rather than after.

The check that matters is the aspect ratio: if the HUD crop ever stops applying,
every clip ships with the answer ("W71.606763 N42.822437") printed across the
bottom and the game is silently ruined. A 16:9 clip means the crop didn't run.

The second is the split: what reaches a browser must carry no coordinates, and
every round needs an answer to score against. A round with no answer is
unplayable (the API 404s it); a coordinate on the round side hands the answer to
the player. The manifest checked here is what rounds.sql is built from, so
asserting on it is asserting on the `rounds` table it becomes.

The media is the one part that can be absent -- it is far too big to keep around
on a machine that only wants to look at a set. So a directory with no clips/ at
all runs in manifest-only mode rather than failing. A clips/ that exists but is
missing a file the manifest names is a real failure, not that mode.
"""

import json
import math
import re
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
# An answer is a circle, because a round plays for a few seconds and the van keeps
# moving: radius_m is how far it gets. The floor is what the coordinate itself is
# worth -- a HUD read is good to a few metres, and the nearest track sample can sit
# up to a second away -- and the ceiling is where make_rounds.py drops the round
# instead of widening the circle, since past it either the van was on a motorway,
# where nobody can name the spot, or its track is lying about where it went.
MIN_RADIUS_M, MAX_RADIUS_M = 25.0, 250.0
# Lower 48, generously bounded.
LAT_RANGE, LNG_RANGE = (24.0, 49.5), (-125.0, -66.0)
# A round's filename has to name the moment it was cut from, not just the clip:
# `clips/<slug>-<milliseconds>.mp4`. That is what lets a deleted clip be rebuilt
# to the same URL, and what makes a long immutable cache header safe.
CLIP_NAME = re.compile(r"^clips/(.+)-(\d{6,})\.mp4$")
# Corpus clips whose location is public. The round sets committed before scoring
# moved server-side carried lat/lng in web/rounds.json, and this is a public
# repo, so git history answers any round cut from one of those clips -- ground
# truth is clip-level, so the moment does not matter. make_rounds.py keeps them
# out of every pool it draws; the assertion in main() catches a set built any
# other way.
LEAKED_SLUGS_FILE = Path(__file__).parent / "leaked_slugs.txt"


def leaked_slugs() -> frozenset:
    """Slugs whose coordinates are recoverable from this repo's git history."""
    lines = LEAKED_SLUGS_FILE.read_text().splitlines()
    return frozenset(s.strip() for s in lines if s.strip() and not s.startswith("#"))


def beside(web: Path, name: str, required: bool = True) -> Path | None:
    """Find a round set's JSON beside clips/, or one level up from it.

    A staged set has all of it in one directory. A swapped-in one has clips/
    under web/ and both JSON files at the repo root, because web/ is the whole
    deployed surface and neither file is for players -- one is the answer key,
    and the other is a pool D1 already holds.
    """
    for candidate in (web / name, web.parent / name):
        if candidate.is_file():
            return candidate
    if required:
        raise FileNotFoundError(f"no {name} in {web} or {web.parent}")
    return None


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
    "pool / 5 days before anything repeats" describes a draw this game does not
    implement. Repeats begin in the first week or two at any pool size worth
    having; what a bigger pool buys is how *often* one comes round again, not
    whether.

    Each of the `5 * days` draws is uniform over the pool and independent, so the
    chance a given round is never drawn is (1 - 1/pool)**draws, i.e. e**-(d/pool)
    for a pool of any size. Expected distinct rounds follows, and everything else
    served was something the player had already seen.

    Checked against the real draw in test_check.py rather than trusted: this is
    the number that says whether a set is big enough, and a wrong one in the
    reassuring direction goes unnoticed indefinitely.
    """
    draws = ROUNDS_PER_GAME * days
    distinct = pool * (1 - math.exp(-draws / pool))
    return round(distinct), (draws - distinct) / draws


def main() -> int:
    web = Path(sys.argv[1]) if len(sys.argv) > 1 else WEB
    rounds = json.loads(beside(web, "rounds.json").read_text())
    assert rounds, "rounds.json is empty"
    assert len(rounds) >= ROUNDS_PER_GAME, (
        f"only {len(rounds)} rounds; a daily game needs {ROUNDS_PER_GAME}"
    )

    answers_file = beside(web, "answers.json", required=False)
    answers = (
        {a["image"]: a for a in json.loads(answers_file.read_text())}
        if answers_file
        else {}
    )

    # No clips/ at all is CI, which has the manifest and nothing else. A clips/
    # that exists and is missing something the manifest names is a broken set --
    # the distinction is deliberate, because "the media isn't here" must not be
    # the same sentence as "the media is here and wrong".
    media = (web / "clips").is_dir()

    seen = set()
    leaked = leaked_slugs()
    for r in rounds:
        clip = web / r["image"]
        assert r["image"] == f"clips/{Path(r['image']).name}", (
            f"round is not under clips/: {r['image']}"
        )
        # The name has to carry the moment, not just the clip. `rounds:rebuild`
        # re-cuts from it, and a long immutable cache header is only safe while a
        # regeneration cannot put different footage behind a name someone already
        # holds. Unconditional: every set this validates was built by the current
        # make_rounds.py, since there is no longer a set in git to inherit.
        moment = CLIP_NAME.match(r["image"])
        assert moment, (
            f"{r['image']} does not name the moment it was cut from -- a round is "
            f"clips/<slug>-<milliseconds>.mp4, so a rebuild lands at the same URL"
        )
        assert moment.group(1) not in leaked, (
            f"{r['image']} is cut from a clip whose location is already public in "
            f"this repo's git history (leaked_slugs.txt) -- the answer is a "
            f"`git log` away, so it must not be a round"
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

        # These fields become the `rounds` table, and /api/day hands a browser a
        # row from it. A coordinate here is the answer, given away before the
        # guess. The separation is table-versus-table now rather than
        # manifest-versus-database, and this is where it gets enforced.
        leaked = {"lat", "lng", "state", "filmed"} & r.keys()
        assert not leaked, (
            f"{r['image']}: a round is served to the player -- it must not carry "
            f"{sorted(leaked)}"
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

        # The provenance of the moment: which corpus clip, and where in it. It is
        # the only record of which frame a round actually is, so a set that loses
        # it cannot be rebuilt or corrected. answers.json is where it is
        # generated; rounds.sql is what puts it into the database, on the side of
        # the split no player can read.
        assert a.get("slug") and a["image"].startswith(f"clips/{a['slug']}-"), (
            f"answer's slug does not match its filename: {a}"
        )
        for field in ("source_ts_sec", "clip_ts_sec"):
            assert a.get(field) is not None and a[field] >= 0, (
                f"missing {field}, so this round cannot be re-cut: {a}"
            )
        # A clip is a window into its original, so a moment is at least as far
        # into the original as it is into the clip -- equal for the 97% that are
        # not trims. Catches the two timelines being confused for each other,
        # which reads as a coordinate that is merely a bit off.
        assert a["source_ts_sec"] >= a["clip_ts_sec"], (
            f"source_ts_sec is before clip_ts_sec, so the two timelines have been "
            f"mixed up: {a}"
        )
        assert MIN_RADIUS_M <= a.get("radius_m", 0) <= MAX_RADIUS_M, (
            f"radius_m outside {MIN_RADIUS_M:g}-{MAX_RADIUS_M:g} m: {a}"
        )

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
    # How wide the answers actually are. The tight end is the van stopped or
    # crawling; the wide end is a few seconds of motorway, where the answer is
    # genuinely a stretch of road rather than a place.
    radii = sorted(a["radius_m"] for a in coords)
    print(
        f"    answer circles: tightest {radii[0]:.0f} m, median "
        f"{radii[len(radii) // 2]:.0f} m, widest {radii[-1]:.0f} m"
    )
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
