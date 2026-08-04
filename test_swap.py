#!/usr/bin/env python3
"""Cover the swap that puts a generated round set into place.

Worth testing because it is the one piece of make_rounds.py that deletes anything:
it replaces the clips the game is serving, and a swap that clears the old ones
before the new ones are ready leaves the game with none.
"""

import json
import tempfile
from pathlib import Path

from make_rounds import swap_in, write_answers


def build(root: Path, name: str, clips: list[str], generated: bool = True) -> Path:
    """Write a round-set directory: clips/*.mp4 and the four generated files.

    `generated=False` builds a *served* directory, which is what web/ looks like:
    only the media belongs inside it, so a swap is the only thing that could put
    the rest there.
    """
    d = root / name
    (d / "clips").mkdir(parents=True)
    for f in clips:
        (d / "clips" / f).write_text(name)
    if not generated:
        return d
    rounds = [
        {"image": f"clips/{f}", "median_km": 40.0, "mean_cos": 0.07} for f in clips
    ]
    answers = [
        {
            "image": f"clips/{f}",
            "lat": 40.0,
            "lng": -100.0,
            "state": name,
            "filmed": "2018-01-01",
            "slug": Path(f).stem,
            "source_ts_sec": 20.0,
            "clip_ts_sec": 20.0,
            "radius_m": 60.0,
        }
        for f in clips
    ]
    (d / "rounds.json").write_text(json.dumps(rounds))
    (d / "rounds.sql").write_text("-- pool and schedule\n")
    write_answers(answers, d)
    return d


def served(web: Path, root: Path) -> tuple[set[str], list[str]]:
    """What web/ is serving, and what the set at the root says it is.

    Two directories, because that is the split: the media is the only part of a
    round set that lives under web/, and everything describing it sits outside.
    """
    manifest = json.loads((root / "rounds.json").read_text())
    return {p.name for p in (web / "clips").iterdir()}, [r["image"] for r in manifest]


def main() -> None:
    with tempfile.TemporaryDirectory() as tmp:
        # One directory per case, because the generated files land beside web/
        # rather than inside it -- so cases sharing a parent would read each
        # other's, and a "a failed swap changed nothing" assertion would be
        # passing on the previous case's leftovers.
        cases = Path(tmp)
        case = lambda n: (cases / n).resolve()  # noqa: E731
        for n in ("one", "two", "three", "four", "five"):
            (cases / n).mkdir()

        # The ordinary case: a live set is replaced wholesale, and the set that
        # lands describes the clips that landed with it.
        root = case("one")
        web = build(root, "web", ["old-a.mp4", "old-b.mp4"], generated=False)
        staging = build(root, "staging", ["new-a.mp4"])
        swap_in(staging, web)
        clips, images = served(web, root)
        assert clips == {"new-a.mp4"}, clips
        assert images == ["clips/new-a.mp4"], images
        assert (web / "clips" / "new-a.mp4").read_text() == "staging"
        assert not staging.exists(), "staging directory outlived the swap"
        assert not (web / "clips.old").exists(), "old clips outlived the swap"

        # The answers land beside the repo, and the new set's replace the old.
        answers = json.loads((root / "answers.json").read_text())
        assert [a["image"] for a in answers] == ["clips/new-a.mp4"], answers
        assert (root / "answers.sql").is_file(), "no answers seed after the swap"
        assert (root / "rounds.sql").is_file(), "no rounds seed after the swap"

        # The property the whole split exists for: web/ is the deployed directory,
        # so anything but the media inside it would be fetchable by a player. The
        # answer key is the obvious one; the pool matters too, because a rounds
        # file in there is a round set that a deploy carries again.
        for leaked in ("answers.json", "answers.sql", "rounds.json", "rounds.sql"):
            assert not (web / leaked).exists(), (
                f"{leaked} landed in the served directory"
            )

        # First run on a fresh checkout: nothing to move aside.
        root = case("two")
        web = root / "empty-web"
        web.mkdir()
        swap_in(build(root, "staging", ["a.mp4"]), web)
        assert served(web, root) == ({"a.mp4"}, ["clips/a.mp4"])

        # A previous run died mid-swap and left clips.old behind. The next swap
        # must clear it rather than refusing to move the current set aside.
        root = case("three")
        web = build(root, "web", ["live.mp4"], generated=False)
        (web / "clips.old").mkdir()
        (web / "clips.old" / "stale.mp4").write_text("stale")
        swap_in(build(root, "staging", ["fresh.mp4"]), web)
        clips, _ = served(web, root)
        assert clips == {"fresh.mp4"}, clips
        assert not (web / "clips.old").exists()

        # The contract: an incomplete staged set costs nothing. Getting this wrong
        # is invisible in the end state of a *successful* swap, which is why it is
        # asserted separately.
        root = case("four")
        web = build(root, "web", ["live.mp4"], generated=False)
        (root / "rounds.json").write_text(json.dumps([{"image": "clips/live.mp4"}]))
        half_built = root / "staging"
        (half_built / "clips").mkdir(parents=True)
        try:
            swap_in(half_built, web)
            raise AssertionError("swapped in a set with no manifest")
        except FileNotFoundError:
            pass
        assert served(web, root) == ({"live.mp4"}, ["clips/live.mp4"]), (
            "a failed swap damaged the served round set"
        )

        # Same contract for each generated file in turn: a set whose clips are cut
        # but whose seed scripts never got written is incomplete. Swapping one in
        # would leave the game serving rounds nothing can score, or a schedule
        # nothing was pushed for.
        for missing in ("rounds.sql", "answers.sql", "answers.json"):
            root = case("five") / missing
            root.mkdir()
            web = build(root, "web", ["live.mp4"], generated=False)
            (root / "rounds.json").write_text(json.dumps([{"image": "clips/live.mp4"}]))
            incomplete = build(root, "staging", ["fresh.mp4"])
            (incomplete / missing).unlink()
            try:
                swap_in(incomplete, web)
                raise AssertionError(f"swapped in a set with no {missing}")
            except FileNotFoundError:
                pass
            assert served(web, root) == ({"live.mp4"}, ["clips/live.mp4"]), (
                f"a swap that failed on {missing} damaged the served round set"
            )

    print("ok: round-set swap replaces the served set, and cleans up after itself")
    print("ok: only the media lands under web/, and an incomplete set moves nothing")


if __name__ == "__main__":
    main()
