#!/usr/bin/env python3
"""Check the reporting in check.py. Run with `python3 test_check.py`.

check.py's aspect-ratio assertion is what stands between an uncropped clip and
the served game, and it is only as good as the dimensions it reads. A reader
that returned a plausible wrong size would pass clips with the answer printed
across the bottom, so the sizes are pinned here rather than trusted.

The media is not committed, so CI never sees it and the HUD-crop check runs only
where the clips exist -- on the laptop that generated them. These assertions are
the only thing standing behind that one.
"""

import os
import shutil
import subprocess
import tempfile
from pathlib import Path

from check import NEAR_KM, clustering, dimensions, km, repeat_rate

HERE = Path(__file__).parent
tmp = tempfile.TemporaryDirectory()

have_ffmpeg = bool(shutil.which("ffmpeg") and shutil.which("ffprobe"))
# Skipping is fine on a laptop that has no ffmpeg -- it has no clips to read
# either. In CI it is not: these assertions stand behind the HUD-crop check, and
# a skip there is a green step that tested nothing, which is how the reader went
# unverified for a whole PR. pr-gates.yml installs ffmpeg; this is what notices
# if that ever stops being true.
assert have_ffmpeg or not os.environ.get("CI"), (
    "CI has no ffmpeg/ffprobe, so the clip-dimension reader would go unchecked"
)

# The reader, against files ffmpeg makes on the spot.
if have_ffmpeg:

    def made(name: str, *args: str) -> Path:
        path = Path(tmp.name) / name
        subprocess.run(
            ["ffmpeg", "-y", "-loglevel", "error", *args, str(path)], check=True
        )
        return path

    def sized(name: str, w: int, h: int) -> Path:
        return made(
            name, "-f", "lavfi", "-i", f"testsrc=size={w}x{h}", "-frames:v", "1"
        )

    # Width and height the right way round -- swapping them is the mistake that
    # turns a cropped 1280x674 clip into an aspect the check would still accept.
    assert dimensions(sized("wide.mp4", 1280, 674)) == (1280, 674)
    assert dimensions(sized("tall.mp4", 674, 1280)) == (674, 1280)

    # Anything that isn't a readable single-video-stream file must raise rather
    # than return something the aspect check would wave through: a wrong answer
    # here ships the coordinates.
    junk = Path(tmp.name) / "junk.mp4"
    junk.write_bytes(b"not an mp4 at all!!!")
    empty = Path(tmp.name) / "empty.mp4"
    empty.write_bytes(b"")
    # A container with no video track at all is what a seek past the last frame
    # produces -- ffmpeg writes it and exits 0, so it is the case that has to
    # fail here rather than reaching a player as a black pane.
    audio = made("audio.mp4", "-f", "lavfi", "-i", "sine=d=1", "-c:a", "aac")
    for bad in (junk, empty, audio, Path(tmp.name) / "absent.mp4"):
        try:
            dimensions(bad)
        except AssertionError:
            pass
        else:
            raise AssertionError(f"expected a failure reading {bad.name}")

# And a real clip, if one has been generated here -- the thing it actually reads.
# web/clips/ is gitignored, so this is a no-op in CI and bites on the laptop.
clip = next(iter(sorted((HERE / "web" / "clips").glob("*.mp4"))), None)
if clip:
    w, h = dimensions(clip)
    assert w / h > 16 / 9, f"{clip.name} is {w}x{h}, which is not a cropped clip"

# The repeat estimate, against the draw it claims to describe. These pool sizes
# and percentages were read off a simulation of dailyRounds() from web/daily.js
# over 90 days -- run it again if this ever fails rather than adjusting the
# numbers to match, since the whole point is that check.py's previous claim
# ("pool / 5 days before anything repeats") described a draw nobody implemented
# and nothing caught it.
for pool, distinct_sim, repeat_sim in ((300, 233, 0.48), (600, 318, 0.29)):
    distinct, rate = repeat_rate(pool)
    assert abs(distinct - distinct_sim) <= pool * 0.05, (
        f"pool {pool}: estimate says {distinct} distinct rounds, the real draw "
        f"gives {distinct_sim}"
    )
    assert abs(rate - repeat_sim) < 0.05, (
        f"pool {pool}: estimate says {rate:.0%} repeats, the real draw gives "
        f"{repeat_sim:.0%}"
    )

# A pool of five is one game, drawn again every day: everything repeats.
assert repeat_rate(5)[1] > 0.98, repeat_rate(5)
# And the estimate must never read as roomier than the pool actually is.
assert repeat_rate(300)[0] <= 300

# The spread report. A wrong distance here reads as a well-spread set, which is
# the direction that gets a clustered set shipped without anyone noticing.
# One degree of latitude is 111.19 km on this sphere, anywhere.
assert abs(km({"lat": 40, "lng": -100}, {"lat": 41, "lng": -100}) - 111.19) < 0.1
# A degree of longitude shrinks with the cosine of the latitude; at 60N it halves.
assert abs(km({"lat": 60, "lng": 0}, {"lat": 60, "lng": 1}) - 111.19 / 2) < 0.5
assert km({"lat": 40, "lng": -100}, {"lat": 40, "lng": -100}) == 0


def at(lat, lng, state="CA"):
    return {"lat": lat, "lng": lng, "state": state}


# Both halves of a close pair count as crowded, and a third point far away does
# not -- the count is rounds involved, not pairs, because that is what says how
# much of the set plays as somewhere it has already been.
near = 0.01  # ~1.1 km, comfortably inside NEAR_KM
crowded, state, pct = clustering([at(40, -100), at(40 + near, -100), at(45, -110)])
assert crowded == 2, crowded
assert (state, pct) == ("CA", 100.0), (state, pct)

# A set with nothing within NEAR_KM of anything else is clean.
assert clustering([at(40, -100), at(41, -100), at(42, -100)])[0] == 0
# And the pair either side of the threshold resolves the way it reads.
just_over = (NEAR_KM + 1) / 111.19
assert clustering([at(40, -100), at(40 + just_over, -100)])[0] == 0
just_under = (NEAR_KM - 1) / 111.19
assert clustering([at(40, -100), at(40 + just_under, -100)])[0] == 2

# The top state is the most common one, not the first one seen.
assert clustering([at(0, 0, "ME"), at(0, 20, "CA"), at(0, 40, "CA")])[1] == "CA"

if have_ffmpeg:
    print("ok: clip dimensions read correctly, and unreadable files raise")
else:
    print("skip: no ffprobe here, so the dimension reader went unchecked")
print("ok: the repeat estimate matches a simulation of the real daily draw")
print("ok: the spread report measures real distances and counts rounds, not pairs")
