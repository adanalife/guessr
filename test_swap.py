#!/usr/bin/env python3
"""Cover the swap that puts a generated round set into place.

Worth testing because it is the one piece of make_rounds.py that deletes anything:
it replaces the round set that main deploys, and a swap that clears the old clips
before the new ones are ready leaves the game with none.
"""

import json
import tempfile
from pathlib import Path

from make_rounds import swap_in, write_answers


def build(root: Path, name: str, clips: list[str], answers: bool = True) -> Path:
    """Write a round-set directory: clips/*.mp4, a manifest, and the answers.

    `answers=False` builds a *served* directory, which is what web/ looks like: the
    coords live outside it, so a swap is the only thing that could put them there.
    """
    d = root / name
    (d / "clips").mkdir(parents=True)
    for f in clips:
        (d / "clips" / f).write_text(name)
    (d / "rounds.json").write_text(json.dumps([{"image": f"clips/{f}"} for f in clips]))
    if not answers:
        return d
    write_answers(
        [
            {
                "image": f"clips/{f}",
                "lat": 40.0,
                "lng": -100.0,
                "state": name,
                "filmed": "2018-01-01",
            }
            for f in clips
        ],
        d,
    )
    return d


def served(web: Path) -> tuple[set[str], list[str]]:
    manifest = json.loads((web / "rounds.json").read_text())
    return {p.name for p in (web / "clips").iterdir()}, [r["image"] for r in manifest]


def main() -> None:
    with tempfile.TemporaryDirectory() as tmp:
        root = Path(tmp)

        # The ordinary case: a live set is replaced wholesale, and the manifest that
        # lands names the clips that landed with it.
        web = build(root, "web", ["old-a.mp4", "old-b.mp4"], answers=False)
        staging = build(root, "staging", ["new-a.mp4"])
        swap_in(staging, web)
        clips, images = served(web)
        assert clips == {"new-a.mp4"}, clips
        assert images == ["clips/new-a.mp4"], images
        assert (web / "clips" / "new-a.mp4").read_text() == "staging"
        assert not staging.exists(), "staging directory outlived the swap"
        assert not (web / "clips.old").exists(), "old clips outlived the swap"

        # The answers land beside the repo, and the new set's answers replace the
        # old ones.
        answers = json.loads((root / "answers.json").read_text())
        assert [a["image"] for a in answers] == ["clips/new-a.mp4"], answers
        assert (root / "answers.sql").is_file(), "no D1 seed script after the swap"

        # The property the whole split exists for: web/ is the deployed directory,
        # so an answers file inside it would be fetchable by anyone playing.
        for leaked in ("answers.json", "answers.sql"):
            assert not (web / leaked).exists(), (
                f"{leaked} landed in the served directory"
            )

        # First run on a fresh checkout: nothing to move aside.
        web = root / "empty-web"
        web.mkdir()
        swap_in(build(root, "staging2", ["a.mp4"]), web)
        assert served(web) == ({"a.mp4"}, ["clips/a.mp4"])

        # A previous run died mid-swap and left clips.old behind. The next swap
        # must clear it rather than refusing to move the current set aside.
        web = build(root, "web3", ["live.mp4"], answers=False)
        (web / "clips.old").mkdir()
        (web / "clips.old" / "stale.mp4").write_text("stale")
        swap_in(build(root, "staging3", ["fresh.mp4"]), web)
        clips, _ = served(web)
        assert clips == {"fresh.mp4"}, clips
        assert not (web / "clips.old").exists()

        # The contract: an incomplete staged set costs nothing. Getting this wrong
        # is invisible in the end state of a *successful* swap, which is why it is
        # asserted separately.
        web = build(root, "web4", ["live.mp4"], answers=False)
        half_built = root / "staging4"
        (half_built / "clips").mkdir(parents=True)
        try:
            swap_in(half_built, web)
            raise AssertionError("swapped in a set with no manifest")
        except FileNotFoundError:
            pass
        assert served(web) == ({"live.mp4"}, ["clips/live.mp4"]), (
            "a failed swap damaged the served round set"
        )

        # Same contract for the answers: a set whose clips and manifest are ready
        # but whose answers never got written is incomplete. Swapping it in would
        # deploy rounds that nothing can score.
        web = build(root, "web5", ["live.mp4"], answers=False)
        no_answers = build(root, "staging5", ["fresh.mp4"])
        (no_answers / "answers.sql").unlink()
        try:
            swap_in(no_answers, web)
            raise AssertionError("swapped in a set with no answers")
        except FileNotFoundError:
            pass
        assert served(web) == ({"live.mp4"}, ["clips/live.mp4"]), (
            "a failed swap damaged the served round set"
        )

    print("ok: round-set swap replaces the served set, and cleans up after itself")


if __name__ == "__main__":
    main()
