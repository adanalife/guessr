#!/usr/bin/env python3
"""Cover the R2 adapter against a stand-in bucket with R2's call shape --
`get(key, {range, onlyIf})` answering null, an object with no `body` (a
conditional matched), or an object body with a resolved `range` -- and run the
real /clips handler over it.

What is pinned is the translation: that the request's headers reach R2 as a
`Headers` in both slots, and that each of R2's three answers renders as the
status the JavaScript route gives it. The stand-in models the binding, not R2.
"""

import asyncio
from types import SimpleNamespace

from server.clips import clip
from server.r2 import R2

CLIP = "2018_0513_135618_039_opt-025000.mp4"
DATA = b"x" * 5000
ETAG = '"abc"'


class Headers(list):
    """JS Headers iterates as [name, value] pairs, which is all the adapter reads."""


class Bucket:
    def __init__(self):
        self.calls = []

    async def get(self, key, options):
        self.calls.append((key, options))
        if key != f"clips/{CLIP}":
            return None
        sent = dict(options["range"])
        assert options["onlyIf"] is options["range"], "conditionals not passed"
        obj = SimpleNamespace(
            size=len(DATA),
            httpEtag=ETAG,
            writeHttpMetadata=lambda h: h.append(("content-disposition", "inline")),
        )
        if sent.get("if-none-match") == ETAG:
            return obj  # no body: the client has it
        obj.body = DATA
        if sent.get("range") == "bytes=100-199":
            obj.range = {"offset": 100, "length": 100}
        elif sent.get("range") == "bytes=-50":
            obj.range = {"suffix": 50}
        return obj


async def main() -> None:
    bucket = Bucket()
    get_clip = R2(bucket, Headers).get_clip

    def get(name, **headers):
        return clip(get_clip, "GET", name, headers)

    status, body, headers = await get(CLIP)
    assert (status, body) == (200, DATA)
    assert headers["content-disposition"] == "inline", "stored metadata dropped"
    assert headers["etag"] == ETAG
    key, options = bucket.calls[-1]
    assert key == f"clips/{CLIP}" and isinstance(options["range"], Headers)

    status, body, headers = await get(CLIP, range="bytes=100-199")
    assert (status, headers["content-range"]) == (206, "bytes 100-199/5000")
    status, _, headers = await get(CLIP, range="bytes=-50")
    assert (status, headers["content-range"]) == (206, "bytes 4950-4999/5000")

    status, body, _ = await get(CLIP, **{"if-none-match": ETAG})
    assert (status, body) == (304, None), "a matched conditional sent the body"

    status, _, _ = await get("never-uploaded.mp4")
    assert status == 404


asyncio.run(main())
print("ok: the R2 adapter renders each of R2's answers the way the JS route does")
