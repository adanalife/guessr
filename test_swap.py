#!/usr/bin/env python3
"""Cover the swap that puts a generated round set into place.

Worth testing because it is the one piece of make_rounds.py that deletes anything:
it replaces the round set that main deploys, and a swap that clears the old frames
before the new ones are ready leaves the game with none.
"""

import json
import tempfile
from pathlib import Path

from make_rounds import swap_in, write_answers


def build(root: Path, name: str, frames: list[str], answers: bool = True) -> Path:
    """Write a round-set directory: frames/*.jpg, a manifest, and the answers.

    `answers=False` builds a *served* directory, which is what web/ looks like: the
    coords live outside it, so a swap is the only thing that could put them there.
    """
    d = root / name
    (d / "frames").mkdir(parents=True)
    for f in frames:
        (d / "frames" / f).write_text(name)
    (d / "rounds.json").write_text(
        json.dumps([{"image": f"frames/{f}"} for f in frames])
    )
    if not answers:
        return d
    write_answers(
        [
            {
                "image": f"frames/{f}",
                "lat": 40.0,
                "lng": -100.0,
                "state": name,
                "filmed": "2018-01-01",
            }
            for f in frames
        ],
        d,
    )
    return d


def served(web: Path) -> tuple[set[str], list[str]]:
    manifest = json.loads((web / "rounds.json").read_text())
    return {p.name for p in (web / "frames").iterdir()}, [r["image"] for r in manifest]


def main() -> None:
    with tempfile.TemporaryDirectory() as tmp:
        root = Path(tmp)

        # The ordinary case: a live set is replaced wholesale, and the manifest that
        # lands names the frames that landed with it.
        web = build(root, "web", ["old-a.jpg", "old-b.jpg"], answers=False)
        staging = build(root, "staging", ["new-a.jpg"])
        swap_in(staging, web)
        frames, images = served(web)
        assert frames == {"new-a.jpg"}, frames
        assert images == ["frames/new-a.jpg"], images
        assert (web / "frames" / "new-a.jpg").read_text() == "staging"
        assert not staging.exists(), "staging directory outlived the swap"
        assert not (web / "frames.old").exists(), "old frames outlived the swap"

        # The answers land beside the repo, and the new set's answers replace the
        # old ones.
        answers = json.loads((root / "answers.json").read_text())
        assert [a["image"] for a in answers] == ["frames/new-a.jpg"], answers
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
        swap_in(build(root, "staging2", ["a.jpg"]), web)
        assert served(web) == ({"a.jpg"}, ["frames/a.jpg"])

        # A previous run died mid-swap and left frames.old behind. The next swap
        # must clear it rather than refusing to move the current set aside.
        web = build(root, "web3", ["live.jpg"], answers=False)
        (web / "frames.old").mkdir()
        (web / "frames.old" / "stale.jpg").write_text("stale")
        swap_in(build(root, "staging3", ["fresh.jpg"]), web)
        frames, _ = served(web)
        assert frames == {"fresh.jpg"}, frames
        assert not (web / "frames.old").exists()

        # The contract: an incomplete staged set costs nothing. Getting this wrong
        # is invisible in the end state of a *successful* swap, which is why it is
        # asserted separately.
        web = build(root, "web4", ["live.jpg"], answers=False)
        half_built = root / "staging4"
        (half_built / "frames").mkdir(parents=True)
        try:
            swap_in(half_built, web)
            raise AssertionError("swapped in a set with no manifest")
        except FileNotFoundError:
            pass
        assert served(web) == ({"live.jpg"}, ["frames/live.jpg"]), (
            "a failed swap damaged the served round set"
        )

        # Same contract for the answers: a set whose frames and manifest are ready
        # but whose answers never got written is incomplete. Swapping it in would
        # deploy rounds that nothing can score.
        web = build(root, "web5", ["live.jpg"], answers=False)
        no_answers = build(root, "staging5", ["fresh.jpg"])
        (no_answers / "answers.sql").unlink()
        try:
            swap_in(no_answers, web)
            raise AssertionError("swapped in a set with no answers")
        except FileNotFoundError:
            pass
        assert served(web) == ({"live.jpg"}, ["frames/live.jpg"]), (
            "a failed swap damaged the served round set"
        )

    print("ok: round-set swap replaces the served set, and cleans up after itself")


if __name__ == "__main__":
    main()
