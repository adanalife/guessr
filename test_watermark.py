#!/usr/bin/env python3
"""Check that a cut clip carries the mark and the credit. Run with
`python3 test_watermark.py`.

Both are things that fail silently. A malformed filter chain makes ffmpeg exit
non-zero and `extract_clip` returns False, which a run notices immediately -- but
a chain that drops the overlay input, or metadata flags that land on the wrong
muxer, produce a perfectly good clip with nothing on it. Nothing downstream
looks: check.py guards the HUD crop and the container, neither of which a missing
watermark disturbs, so the first report would be someone finding an unmarked clip
reposted.

The control is the same `extract_clip` with a *transparent* mark rather than a
hand-rolled unmarked cut. That matters for two reasons: the encode settings
cannot drift out of step with the real ones, since there is only one copy of
them; and every pixel-format conversion the overlay filter introduces happens on
both sides, so a difference between the two is the mark itself rather than an
artefact of the chain.

The assertion is a difference, not a pixel value -- the opacity is a knob in
watermark.png (see make_rounds.WATERMARK), and pinning colours here would turn
retuning it into a test failure.
"""

import os
import shutil
import subprocess
import tempfile
from pathlib import Path

import make_rounds
from make_rounds import WATERMARK, WATERMARK_MARGIN_PX, extract_clip

tmp = tempfile.TemporaryDirectory()
HERE = Path(tmp.name)

have_ffmpeg = bool(shutil.which("ffmpeg") and shutil.which("ffprobe"))
# Same bargain test_check.py makes: skipping on a laptop with no ffmpeg is fine,
# because that laptop cuts no clips either. Skipping in CI is a green step that
# tested nothing.
assert have_ffmpeg or not os.environ.get("CI"), (
    "CI has no ffmpeg/ffprobe, so the watermark and credit would go unchecked"
)


def ffmpeg(*args: str) -> None:
    subprocess.run(["ffmpeg", "-y", "-loglevel", "error", *args], check=True)


if have_ffmpeg:
    # A synthetic corpus: one clip named the way extract_clip expects to find it,
    # and long enough that a 3 s window an inch into it is not the tail.
    corpus = HERE / "corpus"
    corpus.mkdir()
    slug = "2018_0101_000000_000_opt"
    ffmpeg(
        "-f",
        "lavfi",
        "-i",
        f"testsrc=size=1920x1080:duration=6:rate={make_rounds.FPS}",
        str(corpus / f"{slug}.MP4"),
    )
    make_rounds.CORPUS = corpus
    row = {"slug": slug, "ts": 1.0}

    marked = HERE / "marked.mp4"
    assert extract_clip(row, marked), "the synthetic source should cut cleanly"

    # The control mark: same asset, same size, no opacity at all.
    invisible = HERE / "invisible.png"
    ffmpeg("-i", str(WATERMARK), "-vf", "colorchannelmixer=aa=0", str(invisible))
    make_rounds.WATERMARK = invisible
    plain = HERE / "plain.mp4"
    assert extract_clip(row, plain), "the transparent-mark control should cut too"

    def corner(clip: Path, name: str, x: str, y: str) -> bytes:
        """One corner of a clip's first frame, as raw pixels."""
        out = HERE / name
        size = WATERMARK_MARGIN_PX * 2 + 104
        ffmpeg(
            "-i",
            str(clip),
            "-frames:v",
            "1",
            "-vf",
            f"crop={size}:{size}:{x}:{y}",
            "-f",
            "rawvideo",
            "-pix_fmt",
            "rgb24",
            str(out),
        )
        return out.read_bytes()

    def bottom_right(clip: Path, name: str) -> bytes:
        return corner(clip, name, "iw-out_w", "ih-out_h")

    def top_left(clip: Path, name: str) -> bytes:
        return corner(clip, name, "0", "0")

    assert bottom_right(marked, "marked-br.rgb") != bottom_right(
        plain, "plain-br.rgb"
    ), (
        "the bottom-right corner is identical to a transparent-mark cut -- the "
        "overlay did not land"
    )
    # The opposite corner pins *where*: a chain that tinted the whole frame, or a
    # margin that put the mark somewhere else, would pass the assertion above.
    assert top_left(marked, "marked-tl.rgb") == top_left(plain, "plain-tl.rgb"), (
        "the top-left corner differs too, so something other than the corner "
        "mark changed between the two cuts"
    )

    tags = subprocess.run(
        [
            "ffprobe",
            "-v",
            "error",
            "-show_entries",
            "format_tags",
            "-of",
            "default=noprint_wrappers=1",
            str(marked),
        ],
        capture_output=True,
        text=True,
        check=True,
    ).stdout
    assert make_rounds.CREDIT in tags, f"no credit in the container: {tags!r}"
    assert make_rounds.CREDIT_URL in tags, f"no credit URL in the container: {tags!r}"

print("ok" if have_ffmpeg else "ok (skipped: no ffmpeg)")
