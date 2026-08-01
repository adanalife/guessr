#!/usr/bin/env python3
"""Check the JPEG header reader in check.py. Run with `python3 test_check.py`.

check.py's aspect-ratio assertion is what stands between an uncropped frame and
the served game, and it is only as good as the dimensions it reads. A reader
that returned a plausible wrong size would pass frames with the answer printed
across the bottom, so the sizes are pinned here rather than trusted.
"""

import struct
import tempfile
from pathlib import Path

from check import EASY_KM, HARD_KM, dimensions

HERE = Path(__file__).parent


def jpeg(width: int, height: int, marker: int = 0xFFC0) -> bytes:
    """A JPEG header: SOI, a segment to skip over, then a frame header."""
    sof = struct.pack(">HHBHHB", marker, 11, 8, height, width, 3)
    return b"\xff\xd8" + b"\xff\xe0" + struct.pack(">H", 6) + b"JFIF" + sof


tmp = tempfile.TemporaryDirectory()
count = 0


def written(data: bytes) -> Path:
    global count
    count += 1
    path = Path(tmp.name) / f"{count}.jpg"
    path.write_bytes(data)
    return path


# Width and height are the right way round -- swapping them is the mistake that
# turns a cropped 1280x674 frame into an aspect the check would still accept.
assert dimensions(written(jpeg(1280, 674))) == (1280, 674)
assert dimensions(written(jpeg(674, 1280))) == (674, 1280)

# Progressive JPEGs (SOF2) carry their size in the same place, and an optimizer
# can hand back a progressive file for a baseline one.
assert dimensions(written(jpeg(1280, 674, marker=0xFFC2))) == (1280, 674)

# A file that isn't a JPEG, or is truncated before its frame header, must raise
# rather than return something the aspect check would wave through.
for bad in (b"not a jpeg at all", b"\xff\xd8", jpeg(1280, 674)[:12]):
    try:
        dimensions(written(bad))
    except (AssertionError, struct.error):
        pass
    else:
        raise AssertionError(f"expected a failure reading {bad[:16]!r}")

# And a real frame from the committed round set, which is the thing it actually
# reads: cropped, so wider than the 16:9 the dashcam films.
frame = next(iter(sorted((HERE / "web" / "frames").glob("*.jpg"))), None)
if frame:
    w, h = dimensions(frame)
    assert w / h > 16 / 9, f"{frame.name} is {w}x{h}, which is not a cropped frame"

# check.py's band assertion only means something if it buckets rounds the way the
# page does, and the cutoffs are spelled out in both files. Drift would let a set
# through whose bands are empty where it counts -- in play.
daily_js = (HERE / "web" / "daily.js").read_text()
for name, value in (("EASY_KM", EASY_KM), ("HARD_KM", HARD_KM)):
    assert f"const {name} = {value:g};" in daily_js, (
        f"{name} is {value:g} in check.py but not in web/daily.js"
    )

print("ok: JPEG dimensions read correctly, and bad files raise")
print("ok: the difficulty cutoffs agree with web/daily.js")
