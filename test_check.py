#!/usr/bin/env python3
"""Check the mp4 header reader in check.py. Run with `python3 test_check.py`.

check.py's aspect-ratio assertion is what stands between an uncropped clip and
the served game, and it is only as good as the dimensions it reads. A reader
that returned a plausible wrong size would pass clips with the answer printed
across the bottom, so the sizes are pinned here rather than trusted.

This matters more than it did when a round was a JPEG. The media is no longer
committed, so CI never sees it and the HUD-crop check runs only where the clips
exist -- on the laptop that generated them. These assertions are the only thing
standing behind that one.
"""

import struct
import tempfile
from pathlib import Path

from check import EASY_KM, HARD_KM, dimensions

HERE = Path(__file__).parent


def box(kind: bytes, body: bytes) -> bytes:
    return struct.pack(">I4s", len(body) + 8, kind) + body


def tkhd(width: int, height: int, version: int = 0) -> bytes:
    """A track header. Version only changes the width of the timestamp fields.

    Which is the point of pinning both: the reader counts back from the end of
    the box rather than seeking to a fixed offset, so a version-1 file has to
    come out the same as a version-0 one.
    """
    times = b"\0" * (20 if version == 0 else 32)
    return box(
        b"tkhd",
        bytes([version])
        + b"\0\0\1"  # flags
        + times
        + b"\0" * 8  # reserved
        + b"\0" * 8  # layer, alternate_group, volume, reserved
        + b"\0" * 36  # matrix
        + struct.pack(">II", width << 16, height << 16),
    )


def mp4(width: int, height: int, version: int = 0, tracks: int = 1) -> bytes:
    trak = box(b"trak", tkhd(width, height, version))
    return box(b"ftyp", b"isom" + b"\0" * 8) + box(b"moov", trak * tracks)


tmp = tempfile.TemporaryDirectory()
count = 0


def written(data: bytes) -> Path:
    global count
    count += 1
    path = Path(tmp.name) / f"{count}.mp4"
    path.write_bytes(data)
    return path


# Width and height are the right way round -- swapping them is the mistake that
# turns a cropped 1280x674 clip into an aspect the check would still accept.
assert dimensions(written(mp4(1280, 674))) == (1280, 674)
assert dimensions(written(mp4(674, 1280))) == (674, 1280)

# A version-1 tkhd puts eight-byte timestamps ahead of the dimensions, so a
# reader seeking to a fixed offset would be twelve bytes off and silently wrong.
assert dimensions(written(mp4(1280, 674, version=1))) == (1280, 674)

# 16.16 fixed point, so a dimension that isn't a whole number of pixels has to
# round to the pixel rather than truncate toward zero.
almost = box(b"ftyp", b"isom" + b"\0" * 8) + box(
    b"moov",
    box(
        b"trak",
        box(
            b"tkhd",
            b"\0\0\0\1" + b"\0" * 72 + struct.pack(">II", (1280 << 16) - 1, 674 << 16),
        ),
    ),
)
assert dimensions(written(almost)) == (1280, 674)

# A 64-bit box size (size field of 1, real size in the next eight bytes) is legal
# and appears on large files. Reading the 1 as the size would walk off into noise.
body = box(b"trak", tkhd(1280, 674))
large = box(b"ftyp", b"isom" + b"\0" * 8) + (
    struct.pack(">I4sQ", 1, b"moov", len(body) + 16) + body
)
assert dimensions(written(large)) == (1280, 674)

# Anything that isn't a readable single-track mp4 must raise rather than return
# something the aspect check would wave through: a wrong answer here ships the
# coordinates. Two tracks means -an stopped applying, so the reader would be
# measuring whichever track came first rather than the video.
for bad in (
    b"not an mp4 at all!!!",
    b"",
    mp4(1280, 674)[:20],
    box(b"ftyp", b"isom"),  # no moov
    mp4(1280, 674, tracks=2),
    box(b"ftyp", b"isom" + b"\0" * 8) + box(b"moov", box(b"trak", b"")),  # no tkhd
):
    try:
        dimensions(written(bad))
    except (AssertionError, struct.error):
        pass
    else:
        raise AssertionError(f"expected a failure reading {bad[:16]!r}")

# And a real clip, if one has been generated here -- the thing it actually reads.
# web/clips/ is gitignored, so this is a no-op in CI and bites on the laptop.
clip = next(iter(sorted((HERE / "web" / "clips").glob("*.mp4"))), None)
if clip:
    w, h = dimensions(clip)
    assert w / h > 16 / 9, f"{clip.name} is {w}x{h}, which is not a cropped clip"

# check.py's band assertion only means something if it buckets rounds the way the
# page does, and the cutoffs are spelled out in both files. Drift would let a set
# through whose bands are empty where it counts -- in play.
daily_js = (HERE / "web" / "daily.js").read_text()
for name, value in (("EASY_KM", EASY_KM), ("HARD_KM", HARD_KM)):
    assert f"const {name} = {value:g};" in daily_js, (
        f"{name} is {value:g} in check.py but not in web/daily.js"
    )

print("ok: mp4 dimensions read correctly, and bad files raise")
print("ok: the difficulty cutoffs agree with web/daily.js")
