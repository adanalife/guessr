#!/usr/bin/env python3
"""Check that check.py's assertions actually fire. Run with `python3 test_check_main.py`.

test_check.py covers the helpers check.py reports with -- the dimension reader,
the distance, the clustering and repeat estimates. This covers the assertions
themselves, which are a different thing: they are the gate, and a gate is only
worth having if it shuts.

Nothing else notices when one stops shutting. check.py runs against the committed
round set on every PR, and that set is good, so a neutered assertion exits 0 and
the step is green -- the run proves the manifest is clean, never that a dirty one
would be caught. Every assertion below survived being replaced with a no-op while
the whole suite stayed passing, which is what this file exists to end.

The one that matters most is the coordinate leak. rounds.json is served to the
browser, so a lat/lng reaching it hands over the answer and the game is solved in
devtools -- and the manifest is the half of a round set that CI *can* see, making
this the assertion with the most to lose from going quiet.
"""

import contextlib
import io
import json
import os
import shutil
import subprocess
import sys
import tempfile
from pathlib import Path

import check
from check import EASY_KM, HARD_KM, ROUNDS_PER_GAME

have_ffmpeg = bool(shutil.which("ffmpeg") and shutil.which("ffprobe"))
# Same bargain as test_check.py: no ffmpeg on a laptop with no clips is fine, in
# CI it is a green step that skipped the media assertions. pr-gates.yml installs
# it.
assert have_ffmpeg or not os.environ.get("CI"), (
    "CI has no ffmpeg/ffprobe, so the HUD-crop assertion would go unchecked"
)

# One round per band, so the difficulty-spread assertion is satisfied by default
# and each case below fails for the reason it is testing rather than this one.
BANDS = [EASY_KM - 10, EASY_KM + 10, HARD_KM + 10, EASY_KM - 5, HARD_KM + 50]


def rounds(n: int = ROUNDS_PER_GAME) -> list[dict]:
    # The moment is part of the filename, so a rebuild lands at the same URL --
    # `clip_0-020000.mp4` is clip_0 at 20 s.
    return [
        {
            "image": f"clips/clip_{i}-{(i + 1) * 20000:06d}.mp4",
            "median_km": BANDS[i % len(BANDS)],
            "mean_cos": 0.07,
        }
        for i in range(n)
    ]


def answers(manifest: list[dict]) -> list[dict]:
    return [
        {
            "image": r["image"],
            "lat": 40.0,
            "lng": -100.0,
            "state": "CA",
            "filmed": "2018-01-01",
            "slug": f"clip_{i}",
            "source_ts_sec": (i + 1) * 20.0,
            "clip_ts_sec": (i + 1) * 20.0,
            "radius_m": 60.0,
        }
        for i, r in enumerate(manifest)
    ]


def build(
    root: Path,
    name: str,
    manifest: list[dict],
    coords: list[dict] | None = None,
    clips: dict[str, tuple[int, int]] | None = None,
) -> Path:
    """Write a round set. `coords=None` is CI's shape: a manifest and nothing else.

    Each case gets its own directory because check.py looks for answers.json
    beside the set *and* one level up -- sets sharing a parent would read each
    other's.
    """
    d = root / name
    d.mkdir(parents=True)
    (d / "rounds.json").write_text(json.dumps(manifest))
    if coords is not None:
        (d / "answers.json").write_text(json.dumps(coords))
    if clips is not None:
        (d / "clips").mkdir()
        for filename, (w, h) in clips.items():
            subprocess.run(
                [
                    "ffmpeg",
                    "-y",
                    "-loglevel",
                    "error",
                    "-f",
                    "lavfi",
                    "-i",
                    f"testsrc=size={w}x{h}",
                    "-frames:v",
                    "1",
                    str(d / "clips" / filename),
                ],
                check=True,
            )
    return d


def run(web: Path) -> int:
    """check.py's main(), quietly -- it reports at length on a set that passes."""
    argv = sys.argv
    sys.argv = ["check.py", str(web)]
    try:
        with contextlib.redirect_stdout(io.StringIO()):
            return check.main()
    finally:
        sys.argv = argv


def rejects(web: Path, why: str) -> None:
    try:
        run(web)
    except (AssertionError, KeyError):
        return
    raise AssertionError(f"check.py accepted a round set that {why}")


def main() -> None:
    with tempfile.TemporaryDirectory() as tmp:
        root = Path(tmp)

        # The baseline, in both the shapes check.py runs in: CI has the manifest
        # alone, the generating laptop has the answers beside it. Neither must
        # fail, or every rejection below proves nothing.
        assert run(build(root, "ok-manifest", rounds())) == 0
        manifest = rounds()
        assert run(build(root, "ok-answers", manifest, answers(manifest))) == 0

        # THE ONE THAT MATTERS. rounds.json is served, so a coordinate in it is
        # the answer handed to the player -- and this is the assertion that runs
        # on every PR, against a manifest that is always clean.
        for leak in ("lat", "lng", "state", "filmed"):
            dirty = rounds()
            dirty[0][leak] = 40.0 if leak in ("lat", "lng") else "CA"
            rejects(
                build(root, f"leak-{leak}", dirty),
                f"carries {leak} in the served manifest",
            )

        # A manifest too short to draw a game from, or empty entirely.
        rejects(build(root, "empty", []), "is empty")
        rejects(
            build(root, "short", rounds(ROUNDS_PER_GAME - 1)),
            "has fewer rounds than a daily game needs",
        )

        # The same clip twice is the same answer twice -- a game that asks one
        # question two ways.
        dupe = rounds()
        dupe[1]["image"] = dupe[0]["image"]
        rejects(build(root, "dupe", dupe), "names the same round twice")

        # Paths must stay under clips/. Anything else is a manifest pointing at
        # a file the deploy never uploaded, or out of the served directory.
        for path in (
            "clip_0-020000.mp4",
            "../secrets/clip_0-020000.mp4",
            "clips/nested/clip_0-020000.mp4",
        ):
            stray = rounds()
            stray[0]["image"] = path
            rejects(build(root, f"path-{abs(hash(path))}", stray), f"points at {path}")

        # A name with no moment in it. Under the old `<slug>.mp4` a regeneration
        # could put different footage at a URL somebody already had cached, and a
        # deleted clip could not be rebuilt to the name that referenced it.
        for name in ("clips/clip_0.mp4", "clips/clip_0-42.mp4", "clips/clip_0-abc.mp4"):
            momentless = rounds()
            momentless[0]["image"] = name
            rejects(
                build(root, f"moment-{abs(hash(name))}", momentless),
                f"names a clip without its moment: {name}",
            )

        # The scores the ramp and the band report are built from.
        for field in ("median_km", "mean_cos"):
            missing = rounds()
            del missing[0][field]
            rejects(build(root, f"no-{field}", missing), f"is missing {field}")
        negative = rounds()
        negative[0]["median_km"] = -1
        rejects(build(root, "negative-km", negative), "has a negative median_km")

        # A set whose scores all land in one band has nothing for the
        # easy-to-hard ramp to order, so every round plays the same.
        flat = rounds()
        for r in flat:
            r["median_km"] = EASY_KM - 1
        rejects(build(root, "flat", flat), "leaves a difficulty band empty")

        # With the answers alongside: every round needs one, in the lower 48,
        # carrying its labels. A round with no answer is one the API 404s.
        manifest = rounds()
        rejects(
            build(root, "unanswered", manifest, answers(manifest)[1:]),
            "has a round with no answer",
        )
        for field, value in (
            ("lat", 60.0),
            ("lat", 10.0),
            ("lng", -10.0),
            ("lng", -160.0),
            ("state", ""),
            ("filmed", ""),
        ):
            coords = answers(manifest)
            coords[0][field] = value
            rejects(
                build(root, f"answer-{field}-{value}", manifest, coords),
                f"has {field}={value!r} in its answers",
            )

        # The provenance of the moment, which lives only in answers.json. Without
        # it a round cannot be re-cut and a wrong coordinate cannot be corrected,
        # and neither failure is visible in the game -- it plays perfectly.
        for field in ("slug", "source_ts_sec", "clip_ts_sec", "radius_m"):
            coords = answers(manifest)
            del coords[0][field]
            rejects(
                build(root, f"no-answer-{field}", manifest, coords),
                f"is missing {field} in its answers",
            )

        # A slug that does not match the filename means the two disagree about
        # which corpus clip this is, so a rebuild would cut the wrong footage.
        mismatched = answers(manifest)
        mismatched[0]["slug"] = "some_other_clip"
        rejects(
            build(root, "answer-slug-mismatch", manifest, mismatched),
            "has an answer whose slug is not the one in its filename",
        )

        # The answer circle. Too tight claims more precision than a HUD read has;
        # too wide is a round make_rounds.py should have dropped.
        for radius in (0.0, check.MIN_RADIUS_M - 1, check.MAX_RADIUS_M + 1, 5000.0):
            coords = answers(manifest)
            coords[0]["radius_m"] = radius
            rejects(
                build(root, f"answer-radius-{radius:g}", manifest, coords),
                f"has radius_m={radius:g}",
            )

        print(
            "ok: check.py rejects a manifest carrying the answers, and every other bad set"
        )

        # The media assertions. These never run in CI -- web/clips/ is gitignored,
        # so the round set reaches it manifest-only -- which is exactly why the
        # gate they stand in needs checking somewhere.
        if not have_ffmpeg:
            print("skip: no ffmpeg here, so the HUD-crop assertion went unchecked")
            return

        # 1280x674 is a cropped clip; 1280x720 is 16:9, which means the crop did
        # not run and the coordinates are burned across the bottom of the frame.
        manifest = rounds()
        cropped = {r["image"].removeprefix("clips/"): (1280, 674) for r in manifest}
        assert run(build(root, "media-ok", manifest, clips=cropped)) == 0

        uncropped = dict(cropped)
        uncropped[manifest[0]["image"].removeprefix("clips/")] = (1280, 720)
        rejects(
            build(root, "media-hud", manifest, clips=uncropped),
            "ships a 16:9 clip with the coordinates still burned into it",
        )

        # A clips/ that exists and is missing something the manifest names is a
        # broken set, deliberately not the same case as having no media at all.
        short = dict(cropped)
        short.pop(manifest[0]["image"].removeprefix("clips/"))
        rejects(
            build(root, "media-missing", manifest, clips=short),
            "names a clip that is not there",
        )

        # An empty file is what a died-halfway encode leaves; ffprobe reads
        # nothing from it, so it must fail rather than pass by default.
        empty = build(root, "media-empty", manifest, clips=cropped)
        (empty / "clips" / manifest[0]["image"].removeprefix("clips/")).write_bytes(b"")
        rejects(empty, "ships a zero-byte clip")

        print("ok: check.py rejects an uncropped clip, and a set whose media is short")


if __name__ == "__main__":
    main()
