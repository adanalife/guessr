#!/usr/bin/env python3
"""Cover the swap that puts a generated round set into place.

Worth testing because it is the one piece of make_rounds.py that can destroy
something: web/ is the served game and is not in git, so a swap that clears the
old set before the new one is ready has no undo.
"""

import json
import tempfile
from pathlib import Path

from make_rounds import swap_in


def build(root: Path, name: str, frames: list[str]) -> Path:
    """Write a round-set directory: frames/*.jpg plus a manifest naming them."""
    d = root / name
    (d / "frames").mkdir(parents=True)
    for f in frames:
        (d / "frames" / f).write_text(name)
    (d / "rounds.json").write_text(
        json.dumps([{"image": f"frames/{f}"} for f in frames])
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
        web = build(root, "web", ["old-a.jpg", "old-b.jpg"])
        staging = build(root, "staging", ["new-a.jpg"])
        swap_in(staging, web)
        frames, images = served(web)
        assert frames == {"new-a.jpg"}, frames
        assert images == ["frames/new-a.jpg"], images
        assert (web / "frames" / "new-a.jpg").read_text() == "staging"
        assert not staging.exists(), "staging directory outlived the swap"
        assert not (web / "frames.old").exists(), "old frames outlived the swap"

        # First run on a fresh checkout: nothing to move aside.
        web = root / "empty-web"
        web.mkdir()
        swap_in(build(root, "staging2", ["a.jpg"]), web)
        assert served(web) == ({"a.jpg"}, ["frames/a.jpg"])

        # A previous run died mid-swap and left frames.old behind. The next swap
        # must clear it rather than refusing to move the current set aside.
        web = build(root, "web3", ["live.jpg"])
        (web / "frames.old").mkdir()
        (web / "frames.old" / "stale.jpg").write_text("stale")
        swap_in(build(root, "staging3", ["fresh.jpg"]), web)
        frames, _ = served(web)
        assert frames == {"fresh.jpg"}, frames
        assert not (web / "frames.old").exists()

        # The contract: an incomplete staged set costs nothing. Getting this wrong
        # is invisible in the end state of a *successful* swap, which is why it is
        # asserted separately.
        web = build(root, "web4", ["live.jpg"])
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

    print("ok: round-set swap replaces the served set, and cleans up after itself")


if __name__ == "__main__":
    main()
