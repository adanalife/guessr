#!/usr/bin/env python3
"""Cover the Python Worker's own seams with the Workers runtime stood in.

server/worker.py imports `workers`, which exists only under Pyodide, so a
stand-in module is installed before the import. What is pinned:

- the outbound fetch edge-caches the YouTube feed and nothing else. A Twitch
  validate cached by URL would answer one caller's token with another's
  identity, so every other request goes out with no `cf` options at all;
- the clip source hands R2's JS stream back as the bytes chunks an ASGI body
  is written from, and passes a miss or a bodiless answer through untouched.
"""

import asyncio
import sys
import types
from types import SimpleNamespace

sent = []


async def js_fetch(url, method="GET", headers=None, **extra):
    sent.append((url, headers, extra))

    async def text():
        return "body"

    return SimpleNamespace(status=401, text=text)


workers = types.ModuleType("workers")
workers.fetch = js_fetch
workers.asgi = SimpleNamespace(entrypoint=lambda app: app)
sys.modules["workers"] = workers
# R2's JS Headers, stood in as test_server_r2.py does: a list of pairs.
sys.modules["js"] = SimpleNamespace(Headers=SimpleNamespace(new=list))

from server import live, worker  # noqa: E402
from server.admin_auth import VALIDATE_URL  # noqa: E402
from server.clips import Clip  # noqa: E402


class Chunk(bytes):
    def to_bytes(self):
        return bytes(self)


class Stream:
    def __aiter__(self):
        async def gen():
            for part in (b"ab", b"cd"):
                yield Chunk(part)

        return gen()


class Bucket:
    def __init__(self, found):
        self.found = found

    async def get(self, key, options):
        return self.found


async def main() -> None:
    assert await worker.fetch(live.FEED) == (401, "body")
    url, headers, extra = sent.pop()
    assert (url, headers) == (live.FEED, {})
    assert extra["cf"] == {
        "cacheEverything": True,
        "cacheTtlByStatus": {"200-299": live.TTL, "300-599": 0},
    }, extra

    await worker.fetch(VALIDATE_URL, {"Authorization": "OAuth secret"})
    url, headers, extra = sent.pop()
    assert (url, headers) == (VALIDATE_URL, {"Authorization": "OAuth secret"})
    assert extra == {}, f"a Twitch call went out with cache options: {extra}"

    found = SimpleNamespace(
        size=4, httpEtag='"e"', body=Stream(), writeHttpMetadata=lambda h: None
    )
    clip = await worker.clip_source(Bucket(found))("k", {})
    chunks = [c async for c in clip.body]
    assert chunks == [b"ab", b"cd"] and all(type(c) is bytes for c in chunks), chunks

    assert await worker.clip_source(Bucket(None))("k", {}) is None
    bodiless = SimpleNamespace(size=4, httpEtag='"e"', writeHttpMetadata=lambda h: None)
    got = await worker.clip_source(Bucket(bodiless))("k", {})
    assert isinstance(got, Clip) and got.body is None


asyncio.run(main())
print("ok: the Worker edge-caches only the feed, and streams R2 bodies as bytes")
