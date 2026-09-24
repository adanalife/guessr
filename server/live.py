"""GET /api/live -- the video id to show for the channel's stream, or null.

The end-of-game board embeds `/embed/<videoId>`, the only embed form that plays
(the channel-resolving `live_stream?channel=` form renders YouTube error 153), so
an id has to keep arriving on its own. It comes from the channel's Atom feed:
keyless, no Data API quota, newest entry first. Scraping `/live` cannot work from
a datacenter (YouTube answers an unresolved app shell), and `search.list` costs
100 quota units a call. The browser cannot read the feed itself -- no CORS
headers -- which is why this endpoint exists.

`fetch` is the outbound-HTTP seam: an async `(url, headers=None) -> (status, text)` that raises
when no response arrives. Whatever passes it owns edge caching of the upstream;
on Cloudflare that is `cacheTtlByStatus` caching a 2xx for TTL and no error, so a
retry is a real attempt rather than a cached failure. Returns (status, body,
headers).
"""

import re

FEED = "https://www.youtube.com/feeds/videos.xml?channel_id=UC8Q7uFC1Xyr2ZnTWOk9Aizg"

# Five minutes for an answer, half a minute for a failure to reach one. The feed
# is the same bytes for every player, so one read serves every game in the
# window -- but YouTube serves it unreliably (404, 500, 500, 200 seconds apart),
# and a failure cached for five minutes is an empty cell long after it recovered.
TTL, RETRY_TTL = 300, 30

# The first id is the newest video. Matching the one element rather than parsing
# the document keeps markup in a title from mattering. ASCII only, because the id
# goes straight into an embed URL and Python's \w is Unicode.
#
# Not proof the broadcast is live: there is no keyless liveness signal, and a
# quiet channel embeds the replay of the last drive, captioned with a link.
VIDEO_ID = re.compile(r"<yt:videoId>([A-Za-z0-9_-]{11})</yt:videoId>")


def newest_video_id(xml: str) -> str | None:
    m = VIDEO_ID.search(xml)
    return m.group(1) if m else None


async def _read(fetch) -> tuple[str | None, dict]:
    """One attempt. `why["bytes"]` is set on a 2xx and nothing else, so it separates
    "the channel has nothing to show" from "the read did not land" -- the
    distinction the retry and the cache lifetime both turn on, and what keeps a
    resolver that can never resolve from reading like a quiet channel."""
    why: dict = {}
    try:
        status, text = await fetch(FEED)
        why["status"] = status
        if 200 <= status < 300:
            why["bytes"] = len(text)
            return newest_video_id(text), why
    except Exception as e:  # noqa: BLE001 -- a link-only cell beats an empty one
        why["error"] = str(e)
    return None, why


async def live(fetch) -> tuple[int, dict, dict]:
    # Twice, only when the first read never landed: enough to survive one bad
    # roll, and a player waiting on the board should not wait on a third timeout.
    video_id, why = await _read(fetch)
    if "bytes" not in why:
        video_id, why = await _read(fetch)
        why["attempts"] = 2
    ttl = TTL if "bytes" in why else RETRY_TTL
    return (
        200,
        {"videoId": video_id, "why": why},
        {"cache-control": f"public, max-age={ttl}"},
    )
