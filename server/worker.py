"""The Python Worker: server/app.py over the request's own bindings.

api/wrangler.jsonc names this (staged into api/bundle/) as `main`. The bindings arrive in the ASGI scope
with every request, so `context` builds the D1 and R2 adapters from
`request.scope["env"]` rather than at import -- a Python Worker's import runs
once, at deploy, into the memory snapshot every isolate restores from.

Who administers comes from three vars on the Worker, set as secrets:
TWITCH_OWNER_ID, TWITCH_CHANNEL_ID, and TWITCH_CLIENT_IDS (the ids
comma-separated: stage names the staging account as an owner too).
One left unset admits nobody, since no validated token matches an empty id.

Game Center comes from three more -- ASC_KEY_ID, ASC_ISSUER_ID and
ASC_PRIVATE_KEY -- and any one unset switches /api/gamecenter off; stage
leaves them unset.
"""

import base64

from dataclasses import replace

from workers import asgi, fetch as js_fetch

from server import asc, live
from server.admin_auth import admins
from server.app import make_app
from server.d1 import D1
from server.r2 import R2


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


def app_store_connect(request):
    return asc.from_env(request.scope["env"], es256)


async def es256(pem: str, data: bytes) -> bytes:
    """Signs with the .p8's P-256 key over WebCrypto, which is the only crypto a
    Python Worker has. WebCrypto's ECDSA signature is already the raw r||s a
    JWT wants. ponytail: the ffi conversions are modeled, not run, until the
    first stage deploy with the secrets set proves them, as r2.py's were."""
    from js import Object, crypto
    from pyodide.ffi import to_js

    def js(obj):
        return to_js(obj, dict_converter=Object.fromEntries)

    der = base64.b64decode(
        "".join(line for line in pem.splitlines() if "-----" not in line)
    )
    key = await crypto.subtle.importKey(
        "pkcs8",
        to_js(der),
        js({"name": "ECDSA", "namedCurve": "P-256"}),
        False,
        js(["sign"]),
    )
    signature = await crypto.subtle.sign(
        js({"name": "ECDSA", "hash": "SHA-256"}), key, to_js(data)
    )
    return signature.to_bytes()


async def fetch(url, headers=None, method="GET", body=None):
    """The outbound seam over the runtime's fetch. Raises when no response
    arrives, which is what /api/live and the admin gate both expect.

    The feed alone is edge-cached, per status:
    a success for live.TTL, a failure not at all. Nothing else may be -- a
    Twitch validate cached by URL would answer one caller's token with
    another's identity."""
    extra = {}
    if url == live.FEED:
        extra["cf"] = {
            "cacheEverything": True,
            "cacheTtlByStatus": {"200-299": live.TTL, "300-599": 0},
        }
    if body is not None:
        extra["body"] = body
    res = await js_fetch(url, method=method, headers=headers or {}, **extra)
    return res.status, await res.text()


app = make_app(context, fetch, app_store_connect)

Default = asgi.entrypoint(app)
