"""The Python Worker: server/app.py over the request's own bindings.

api/wrangler.jsonc names this (staged into api/bundle/) as `main`. The bindings arrive in the ASGI scope
with every request, so `context` builds the D1 and R2 adapters from
`request.scope["env"]` rather than at import -- a Python Worker's import runs
once, at deploy, into the memory snapshot every isolate restores from.

Who administers comes from three vars on the Worker, set as secrets:
TWITCH_OWNER_ID, TWITCH_CHANNEL_ID, and TWITCH_CLIENT_IDS (comma-separated).
One left unset admits nobody, since no validated token matches an empty id.
"""

from dataclasses import replace

from workers import asgi, fetch as js_fetch

from server import live
from server.admin_auth import Admins
from server.app import make_app
from server.d1 import D1
from server.r2 import R2


def admins(env) -> Admins:
    def var(name):
        # A secret never set reads as absent, and absent is no admin.
        return str(getattr(env, name, None) or "").strip()

    return Admins(
        owner_id=var("TWITCH_OWNER_ID"),
        channel_id=var("TWITCH_CHANNEL_ID"),
        client_ids=frozenset(
            c.strip() for c in var("TWITCH_CLIENT_IDS").split(",") if c.strip()
        ),
    )


async def _chunks(stream):
    """A JS ReadableStream as the bytes chunks an ASGI body is written from."""
    async for chunk in stream:
        yield chunk.to_bytes()


def clip_source(bucket):
    r2 = R2(bucket)

    async def get_clip(key, headers):
        found = await r2.get_clip(key, headers)
        if found is None or found.body is None:
            return found
        return replace(found, body=_chunks(found.body))

    return get_clip


def context(request):
    env = request.scope["env"]
    return D1(env.DB), clip_source(env.CLIPS), admins(env)


async def fetch(url, headers=None):
    """The outbound seam over the runtime's fetch. Raises when no response
    arrives, which is what /api/live and the admin gate both expect.

    The feed alone is edge-cached, per status as functions/api/live.js has it:
    a success for live.TTL, a failure not at all. Nothing else may be -- a
    Twitch validate cached by URL would answer one caller's token with
    another's identity."""
    extra = {}
    if url == live.FEED:
        extra["cf"] = {
            "cacheEverything": True,
            "cacheTtlByStatus": {"200-299": live.TTL, "300-599": 0},
        }
    res = await js_fetch(url, headers=headers or {}, **extra)
    return res.status, await res.text()


app = make_app(context, fetch)

Default = asgi.entrypoint(app)
