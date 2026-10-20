"""Unhandled exceptions to the guessr-server Sentry project, posted as one
envelope through the app's own `fetch` seam.

Hand-built rather than sentry-sdk because a Python Worker has no sockets for
the SDK's urllib3 transport, and every import lands in the memory snapshot each
cold isolate restores. ponytail: an exception's type, message and stack, the
request's method and URL, nothing more; reach for the SDK if releases,
breadcrumbs or tracing ever matter here.

The DSN is a literal for the reason web/sentry-init.js gives: all it permits is
sending events to this one project. What gets sent is chosen to carry no player
data -- the URL's query holds only dates and board names, and neither headers
(an admin's bearer token rides in one) nor a body (a player's id) is read.
"""

import json
import time
import traceback
import uuid
from urllib.parse import urlsplit

DSN = "https://5b4b14ad0a06de9f01eaffb4fdc8a554@o325224.ingest.us.sentry.io/4512189980868608"
ENVELOPE_URL = "https://o325224.ingest.us.sentry.io/api/4512189980868608/envelope/"
AUTH = f"Sentry sentry_version=7, sentry_client=guessr-server/1, sentry_key={urlsplit(DSN).username}"


def event(exc: BaseException, environment: str, method: str, url: str) -> dict:
    frames = [
        {
            "filename": f.filename,
            "function": f.name,
            "lineno": f.lineno,
            "context_line": f.line,
            "in_app": "/server/" in f.filename,
        }
        for f in traceback.extract_tb(exc.__traceback__)
    ]
    return {
        "event_id": uuid.uuid4().hex,
        "timestamp": time.time(),
        "platform": "python",
        "level": "error",
        "environment": environment,
        "exception": {
            "values": [
                {
                    "type": type(exc).__name__,
                    "module": type(exc).__module__,
                    "value": str(exc),
                    "stacktrace": {"frames": frames},
                }
            ]
        },
        "request": {"method": method, "url": url},
    }


def envelope(evt: dict) -> str:
    header = {"event_id": evt["event_id"], "dsn": DSN}
    return "\n".join(json.dumps(part) for part in (header, {"type": "event"}, evt))


async def report(fetch, exc: BaseException, environment: str, method: str, url: str):
    """Posts one event. A tier with no environment set (local, tests) sends
    nothing."""
    if not environment:
        return
    await fetch(
        ENVELOPE_URL,
        headers={
            "Content-Type": "application/x-sentry-envelope",
            "X-Sentry-Auth": AUTH,
        },
        method="POST",
        body=envelope(event(exc, environment, method, url)),
    )
