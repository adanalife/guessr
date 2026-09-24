#!/usr/bin/env python3
"""Cover the Python /api/live: which feed bytes yield a video id, the retry, and
the cache lifetime a failure gets. The same cases test_live.mjs holds the
JavaScript to, with the fetch seam stubbed instead of globalThis.fetch.
"""

import asyncio

from server.live import TTL, live, newest_video_id


def entry(vid: str, title: str) -> str:
    return f"<entry><yt:videoId>{vid}</yt:videoId><title>{title}</title></entry>"


def feed(*entries: str) -> str:
    return (
        '<?xml version="1.0" encoding="UTF-8"?>'
        '<feed xmlns:yt="http://www.youtube.com/xml/schemas/2015">'
        f"<title>A Dana Life</title>{''.join(entries)}</feed>"
    )


LIVE = feed(
    entry("Uhln8S-ZCMI", "24/7 Driving Around the USA"),
    entry("GS3hnGlX5xI", "an older drive"),
)

assert newest_video_id(LIVE) == "Uhln8S-ZCMI", "the newest entry wins"
assert newest_video_id(feed()) is None and newest_video_id("") is None
assert newest_video_id(feed(entry("short", "too short"))) is None
assert newest_video_id("<yt:videoId>Uhln8S-ZCMI") is None, "an unclosed element"
# \w would pass these into an embed URL.
assert newest_video_id(feed(entry("Uhln8S-ZCMé", "unicode"))) is None
assert newest_video_id(feed(entry("wX2DVKMKF_Y", "WoodenBoat School"))) == "wX2DVKMKF_Y"


def stub(*answers):
    """A fetch answering each call from `answers` in turn; an Exception raises."""
    calls = []

    async def fetch(url):
        calls.append(url)
        a = answers[min(len(calls), len(answers)) - 1]
        if isinstance(a, Exception):
            raise a
        return a

    return fetch, calls


def max_age(headers: dict) -> int:
    return int(headers["cache-control"].rsplit("=", 1)[1])


async def test_live() -> None:
    fetch, calls = stub((200, LIVE))
    status, body, headers = await live(fetch)
    assert status == 200 and body == {
        "videoId": "Uhln8S-ZCMI",
        "why": {"status": 200, "bytes": len(LIVE)},
    }
    assert len(calls) == 1 and max_age(headers) == TTL >= 60

    # A quiet channel is an answer: read, not retried, cached like one.
    fetch, calls = stub((200, "<feed></feed>"))
    _, body, headers = await live(fetch)
    assert body == {"videoId": None, "why": {"status": 200, "bytes": 13}}
    assert len(calls) == 1 and max_age(headers) == TTL

    fetch, calls = stub((429, "nope"))
    _, body, headers = await live(fetch)
    assert body == {"videoId": None, "why": {"status": 429, "attempts": 2}}
    assert len(calls) == 2 and max_age(headers) < TTL, "a failure cached like an answer"

    fetch, calls = stub((500, "nope"), (200, LIVE))
    _, body, headers = await live(fetch)
    assert body["videoId"] == "Uhln8S-ZCMI" and max_age(headers) == TTL

    fetch, calls = stub(OSError("network"))
    _, body, headers = await live(fetch)
    assert body["videoId"] is None and "network" in body["why"]["error"]
    assert len(calls) == 2 and max_age(headers) < TTL


asyncio.run(test_live())
print("ok: the Python /api/live matches the contract test_live.mjs holds")
