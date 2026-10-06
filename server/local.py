"""The app off Cloudflare: a sqlite file, clips in a directory, the static site
beside the API, and outbound HTTP over urllib -- what uvicorn serves on a
machine with no Workers runtime, and what integration_uvicorn.py holds to the
same contract as workerd.

Run it as `task api:serve`, configured from the environment:

- GUESSR_DB: the sqlite file (default answers.db). A new one is created with
  every migration applied; an existing one is used as it stands.
- GUESSR_CLIPS: the directory clips are served from, keyed like the bucket
  (default clips/).
- TWITCH_OWNER_ID, TWITCH_CHANNEL_ID, TWITCH_CLIENT_IDS: who administers, as
  on the Worker (the ids comma-separated). One left unset admits nobody.
- HOST / PORT: where uvicorn listens (default 127.0.0.1:8789).
"""

import asyncio
import hashlib
import os
import re
import urllib.error
import urllib.request
from pathlib import Path

from starlette.staticfiles import StaticFiles

from server.admin_auth import admins
from server.app import make_app
from server.clips import Clip, Range

WEB = Path(__file__).resolve().parent.parent / "web"
RANGE = re.compile(r"bytes=([0-9]*)-([0-9]*)")


def resolve_range(header: str | None, size: int) -> Range | None:
    """A single `bytes=` range as R2 reports it, or None to serve the whole
    object. ponytail: one range only, and an unsatisfiable one is the whole
    object rather than a 416 -- R2's own leniency."""
    m = RANGE.fullmatch(header or "")
    if not m or m.groups() == ("", ""):
        return None
    first, last = m.groups()
    if not first:
        return Range(suffix=min(int(last), size))
    start = int(first)
    if start >= size:
        return None
    if not last:
        return Range(offset=start)
    return Range(offset=start, length=min(int(last), size - 1) - start + 1)


class Files:
    """The `get_clip` seam over a directory holding keys as paths."""

    def __init__(self, root):
        self.root = Path(root).resolve()

    async def get_clip(self, key: str, headers: dict) -> Clip | None:
        path = (self.root / key).resolve()
        # Unlike a bucket's flat keys, a path can climb out of its directory.
        if not path.is_relative_to(self.root) or not path.is_file():
            return None
        data = path.read_bytes()
        etag = f'"{hashlib.md5(data).hexdigest()}"'
        if headers.get("if-none-match") == etag:
            return Clip(size=len(data), etag=etag)
        r = resolve_range(headers.get("range"), len(data))
        if r is None:
            return Clip(size=len(data), etag=etag, body=data)
        start = len(data) - r.suffix if r.suffix is not None else r.offset
        end = len(data) if r.length is None else start + r.length
        return Clip(size=len(data), etag=etag, body=data[start:end], range=r)


async def fetch(url, headers=None, method="GET", body=None):
    """The outbound seam over urllib, off the event loop. Any status is an
    answer; only no response at all raises."""

    def get():
        data = body.encode() if isinstance(body, str) else body
        req = urllib.request.Request(
            url, data=data, headers=headers or {}, method=method
        )
        try:
            with urllib.request.urlopen(req, timeout=10) as res:
                return res.status, res.read().decode()
        except urllib.error.HTTPError as e:
            return e.code, e.read().decode()

    return await asyncio.to_thread(get)


def build(db, clips_root, admins, fetch=fetch):
    """The API with web/ mounted behind it, so one process is the whole site."""
    clips = Files(clips_root)
    app = make_app(lambda request: (db, clips.get_clip, admins), fetch)
    app.mount("/", StaticFiles(directory=WEB, html=True))
    return app


def open_db(path: str):
    """The sqlite file, migrated only when this call creates it: the
    migrations are plain DDL, so replaying them over a live file fails."""
    from server.db import Sqlite

    new = not Path(path).exists()
    db = Sqlite(path)
    return db.migrate() if new else db


def main() -> None:
    import types

    import uvicorn

    env = os.environ
    app = build(
        open_db(env.get("GUESSR_DB", "answers.db")),
        env.get("GUESSR_CLIPS", "clips"),
        admins(types.SimpleNamespace(**env)),
    )
    # One worker, one thread: the sqlite connection belongs to the thread that
    # opened it, which is the one uvicorn's loop runs on.
    uvicorn.run(
        app, host=env.get("HOST", "127.0.0.1"), port=int(env.get("PORT", "8789"))
    )


if __name__ == "__main__":
    main()
