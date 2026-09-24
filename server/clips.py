"""GET /clips/<name>.mp4 -- a round's footage, out of the media store.

The media lives in a private bucket rather than in git or the deploy: a round set
is ~150 MB, the repo is public, and a set can then be published -- or one clip
replaced -- without a deploy. Nothing enumerates the bucket; this route is the
only way in.

`get_clip` is the media-store seam: an async `(key, headers) -> Clip | None`,
None for a key nobody uploaded. `headers` is the request's, lowercase keys, and
goes to the store whole, because R2 parses Range and the conditional headers
itself. The store answers with what it resolved; this module only renders it.

Returns (status, body, headers), where body is whatever the store handed back
(bytes or a stream) rather than a dict, or None when there is nothing to send.
"""

import re
from dataclasses import dataclass, field

# A name carrying the moment it was cut from (`<slug>-<ms>.mp4`) can only ever
# mean one three seconds of footage, so it caches forever. A bare `<slug>.mp4`
# can be regenerated onto a different moment under a URL somebody already holds.
MOMENT_IN_NAME = re.compile(r"-\d{6,}\.mp4$")
YEAR, HOUR = 31536000, 3600


@dataclass(frozen=True)
class Range:
    """Whichever form of the range the store resolved: an offset with a length,
    an offset alone (open-ended), or a suffix counted from the end."""

    offset: int | None = None
    length: int | None = None
    suffix: int | None = None


@dataclass(frozen=True)
class Clip:
    size: int
    etag: str  # quoted, as it goes on the wire
    body: object = None  # None when a conditional matched: the client has it
    range: Range | None = None
    metadata: dict = field(default_factory=dict)  # stored http headers


async def clip(
    get_clip, method: str, name: str, headers: dict
) -> tuple[int, object, dict]:
    # HEAD takes the GET path; the server drops the body.
    if method not in ("GET", "HEAD"):
        return 405, None, {"allow": "GET, HEAD"}
    # Keys are a flat namespace, so `..` is a literal that misses. This keeps
    # the route to one job rather than guarding a boundary.
    if not name.endswith(".mp4"):
        return 404, None, {}

    found = await get_clip(f"clips/{name}", headers)
    # A real 404, never the site's HTML at 200: that is how a deploy with no
    # media reads green and plays as black panes.
    if found is None:
        return 404, None, {}

    out = {
        **found.metadata,
        "etag": found.etag,
        "accept-ranges": "bytes",
        "cache-control": f"public, max-age={YEAR}, immutable"
        if MOMENT_IN_NAME.search(name)
        else f"public, max-age={HOUR}",
        # Set, not inherited: an upload that forgot its content type would serve
        # octet-stream, and a <video> plays that as nothing, silently.
        "content-type": "video/mp4",
    }
    if found.body is None:
        return 304, None, out

    # A 206 only to a client that asked: some players refuse one they did not.
    if found.range and "range" in headers:
        r = found.range
        start = (r.offset or 0) if r.suffix is None else found.size - r.suffix
        end = found.size - 1 if r.length is None else start + r.length - 1
        out["content-range"] = f"bytes {start}-{end}/{found.size}"
        return 206, found.body, out
    return 200, found.body, out
