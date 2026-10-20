#!/usr/bin/env python3
"""Cover server/app.py, the Starlette app every handler is served through: that
a route reaches its handler, that a body which will not parse is the handler's
400, that /admin is refused before anything under it is routed, and that a clip
comes back as bytes or a stream with its headers. The handlers' own cases live
in the other test_server_*.py; this is only the layer between them and HTTP.

Driven over raw ASGI rather than a test client, so it needs Starlette and
nothing else: run it with `uv run --project api python test_server_app.py`.
"""

import asyncio
import datetime as dt
import json

from server import sentry
from server.admin_auth import Admins
from server.app import make_app
from server.clips import Clip
from server.db import Sqlite

TODAY = dt.datetime.now(dt.UTC).date().isoformat()
OWNER_TOKEN, APP = "owner-token", "test-app"
ADMINS = Admins(
    owner_ids=frozenset({"111"}), channel_id="999", client_ids=frozenset({APP})
)


async def fetch(url, headers=None):
    """Twitch, knowing one token: the owner's."""
    if (headers or {}).get("Authorization") == f"OAuth {OWNER_TOKEN}":
        who = {"client_id": APP, "login": "dana", "user_id": "111", "scopes": []}
        return 200, json.dumps(who)
    return 401, "{}"


async def stream():
    yield b"stand-"
    yield b"in"


async def get_clip(key, headers):
    if key == "clips/streamed-123456.mp4":
        return Clip(size=8, etag='"e"', body=stream())
    return None


async def call(app, method, path, body=b"", headers=()):
    path, _, query = path.partition("?")
    scope = {
        "type": "http",
        "method": method,
        "path": path,
        "query_string": query.encode(),
        "headers": [(k.encode(), v.encode()) for k, v in headers],
    }
    inbox = [{"type": "http.request", "body": body, "more_body": False}]
    sent = []

    async def receive():
        return inbox.pop() if inbox else {"type": "http.disconnect"}

    async def send(message):
        sent.append(message)

    await app(scope, receive, send)
    raw = b"".join(m.get("body", b"") for m in sent[1:])
    return (
        sent[0]["status"],
        {k.decode(): v.decode() for k, v in sent[0]["headers"]},
        raw,
    )


async def main() -> None:
    db = Sqlite().migrate()
    for i in range(1, 6):
        image = f"clips/today_{i}-0{i}0000.mp4"
        await db.execute(
            """INSERT INTO rounds (image, median_km, mean_cos, batch, slug, source_ts_sec,
                                   clip_ts_sec, radius_m)
               VALUES (?, 10, 0.07, 'test', 'slug', 20, 20, 60)""",
            image,
        )
        await db.execute(
            "INSERT INTO round_days (date, position, image) VALUES (?, ?, ?)",
            TODAY,
            i,
            image,
        )
    app = make_app(lambda request: (db, get_clip, ADMINS), fetch)

    status, headers, raw = await call(app, "GET", f"/api/day?date={TODAY}")
    assert status == 200, (status, raw)
    assert headers["content-type"] == "application/json", headers
    assert headers["cache-control"] == "public, max-age=86400", headers
    assert len(json.loads(raw)["rounds"]) == 5, raw

    status, headers, raw = await call(app, "POST", "/api/score", b"not json")
    assert status == 400 and "error" in json.loads(raw), (status, raw)

    # Refused before routing: a known route, a method it does not take, and a
    # path nothing serves all answer alike to someone who is not the owner.
    for method, path, auth in [
        ("GET", "/admin/players", ()),
        ("GET", "/admin/review", ()),
        ("GET", "/admin/", ()),
        ("GET", "/admin/nothing-here", (("authorization", "Bearer stranger"),)),
    ]:
        status, headers, raw = await call(app, method, path, headers=auth)
        assert status == 401, (method, path, status, raw)
        assert headers["cache-control"] == "no-store", headers
        assert json.loads(raw)["error"] == "sign in with Twitch", raw

    owner = (("authorization", f"Bearer {OWNER_TOKEN}"),)
    status, _, raw = await call(app, "GET", "/admin/players", headers=owner)
    assert status == 200 and json.loads(raw) == {"players": []}, (status, raw)
    status, _, _ = await call(app, "GET", "/admin/nothing-here", headers=owner)
    assert status == 404, status

    status, headers, raw = await call(app, "GET", "/clips/missing-123456.mp4")
    assert status == 404 and raw == b"", (status, raw)
    status, headers, _ = await call(app, "POST", "/clips/missing-123456.mp4")
    assert status == 405 and headers["allow"] == "GET, HEAD", (status, headers)
    status, headers, raw = await call(app, "GET", "/clips/streamed-123456.mp4")
    assert status == 200 and raw == b"stand-in", (status, raw)
    assert headers["content-type"] == "video/mp4", headers

    # The caller's User-Agent reaches the scorer as a platform bucket on the row,
    # and the answer carries no trace of it.
    play = {
        "image": "clips/today_1-010000.mp4",
        "lat": 40,
        "lng": -100,
        "date": TODAY,
        "player_id": "a3f1c2d4-0000-4000-8000-000000000000",
    }
    await db.execute(
        "INSERT INTO answers (image, lat, lng, state, filmed) VALUES (?, 40, -100, 'CA', '2018-01-01')",
        play["image"],
    )
    status, headers, raw = await call(
        app,
        "POST",
        "/api/score",
        json.dumps(play).encode(),
        headers=[("user-agent", "Guessr/1.13.0 (iPadOS 26.0)")],
    )
    assert status == 200 and "client" not in json.loads(raw), (status, raw)
    assert (await db.fetchone("SELECT client FROM plays"))["client"] == "ipados"

    await uncaught()


class Broken:
    async def fetchall(self, *args):
        raise RuntimeError("d1 is down")

    fetchone = execute = fetchall


async def uncaught() -> None:
    """An exception no handler catches is a plain 500 and reaches `report`, and
    a `report` that itself fails changes nothing the caller sees. Starlette
    re-raises once the 500 is sent, so the runtime logs it too."""
    heard, posted = [], []

    async def post(url, headers=None, method="GET", body=None):
        posted.append((url, headers, body))
        return 200, "{}"

    async def report(request, exc):
        heard.append(exc)
        await sentry.report(post, exc, "stage-1", request.method, str(request.url))

    async def failing(request, exc):
        raise OSError("sentry unreachable")

    for hook in (report, failing):
        app = make_app(lambda request: (Broken(), get_clip, ADMINS), fetch, report=hook)
        sent = []

        async def receive():
            return {"type": "http.request", "body": b"", "more_body": False}

        async def send(message):
            sent.append(message)

        scope = {
            "type": "http",
            "method": "GET",
            "path": "/api/day",
            "query_string": f"date={TODAY}".encode(),
            "headers": [(b"authorization", b"Bearer secret")],
        }
        try:
            await app(scope, receive, send)
        except RuntimeError:
            pass
        assert sent[0]["status"] == 500, sent

    assert [str(e) for e in heard] == ["d1 is down"], heard
    ((url, headers, body),) = posted
    assert url == sentry.ENVELOPE_URL and "sentry_key=" in headers["X-Sentry-Auth"]
    head, item, event = (json.loads(line) for line in body.split("\n"))
    assert head["event_id"] == event["event_id"] and item == {"type": "event"}
    assert event["environment"] == "stage-1", event
    (exc,) = event["exception"]["values"]
    assert exc["type"] == "RuntimeError" and exc["value"] == "d1 is down", exc
    assert any(f["in_app"] for f in exc["stacktrace"]["frames"]), exc
    assert event["request"]["url"].endswith(f"/api/day?date={TODAY}"), event
    assert "secret" not in body, "a request header leaked into the event"


asyncio.run(main())
print("ok: test_server_app")
