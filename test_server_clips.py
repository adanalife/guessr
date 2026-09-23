#!/usr/bin/env python3
"""Cover the Python /clips route: what it serves, what it refuses, and how long
the answer may be cached. The cases test_clips.mjs holds the JavaScript to.

Every way this is wrong is quiet: a missing clip answered as the site at 200 is a
green deploy of black panes, octet-stream is a <video> that plays nothing, and
`immutable` on a regenerable name is a player stuck with the wrong footage for a
year. The store stub models the seam, not R2: it resolves `bytes=` the way R2
reports it, so what is pinned is that the handler renders what comes back.
"""

import asyncio

from server.clips import Clip, Range, clip

CLIP = "2018_0513_135618_039_opt-025000.mp4"
LEGACY = "2018_0701_211825_079_opt.mp4"
# A non-clip key really in the bucket, so refusing it is the route's doing.
OBJECTS = {
    f"clips/{CLIP}": b"x" * 5000,
    f"clips/{LEGACY}": b"y" * 400,
    "clips/index.html": b"<html>",
}
ETAG = '"abc"'


async def store(key, headers):
    body = OBJECTS.get(key)
    if body is None:
        return None
    base = {
        "size": len(body),
        "etag": ETAG,
        "metadata": {
            "content-type": "application/octet-stream",
            "content-disposition": "inline",
        },
    }
    if headers.get("if-none-match") == ETAG:
        return Clip(**base)
    spec = headers.get("range")
    if not spec:
        # A range the client never asked for, which must still answer 200.
        return Clip(**base, body=body, range=Range(offset=0, length=10))
    start, _, stop = spec.removeprefix("bytes=").partition("-")
    if start == "":
        return Clip(**base, body=body, range=Range(suffix=int(stop)))
    length = None if stop == "" else int(stop) - int(start) + 1
    return Clip(**base, body=body, range=Range(offset=int(start), length=length))


def get(name, method="GET", **headers):
    return clip(store, method, name, headers)


async def main() -> None:
    status, body, headers = await get(CLIP)
    assert (status, body) == (200, b"x" * 5000)
    assert headers["content-type"] == "video/mp4", "served the stored octet-stream"
    assert (headers["accept-ranges"], headers["etag"]) == ("bytes", ETAG)
    assert headers["content-disposition"] == "inline", "dropped the stored metadata"

    # THE ONE THAT MATTERS: a clip nobody uploaded is a real, empty 404.
    assert await get("2020_missing-010000.mp4") == (404, None, {})
    for name in ("index.html", "../rounds.json", "clip.mp4.txt", ""):
        assert (await get(name))[0] == 404, name

    # Seeking, in the three forms a video element asks for.
    for spec, want in (
        ("bytes=100-199", "bytes 100-199/5000"),
        ("bytes=4000-", "bytes 4000-4999/5000"),
        ("bytes=-500", "bytes 4500-4999/5000"),
    ):
        status, _, headers = await get(CLIP, range=spec)
        assert (status, headers["content-range"]) == (206, want), spec

    # A conditional that matched: no body, and the headers still say what it is.
    status, body, headers = await get(CLIP, **{"if-none-match": ETAG})
    assert (status, body, headers["etag"]) == (304, None, ETAG)

    # Only a name carrying its moment is immutable.
    assert (await get(CLIP))[2][
        "cache-control"
    ] == "public, max-age=31536000, immutable"
    assert (await get(LEGACY))[2]["cache-control"] == "public, max-age=3600"

    for method in ("POST", "PUT", "DELETE"):
        assert await get(CLIP, method) == (405, None, {"allow": "GET, HEAD"}), method
    status, _, headers = await get(CLIP, "HEAD")
    assert (status, headers["content-type"]) == (200, "video/mp4")


asyncio.run(main())
print("ok: a Python clip streams, seeks, revalidates, and a missing one is a 404")
