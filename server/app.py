"""The HTTP surface: every route the Pages Functions serve, as one Starlette app
over the framework-free handlers beside it.

ASGI is the point of Starlette here. The same app runs under Python Workers'
`workers.asgi` connector on Cloudflare (server/worker.py) and under uvicorn
anywhere else, so moving host is a new `context`, never a new router.

`context(request) -> (db, get_clip, admins)` is asked once per request, because
on Cloudflare the bindings arrive with the request (`request.scope["env"]`) and
not at import. Anywhere they are fixed it is a lambda returning the same three.
`fetch` is the outbound-HTTP seam /api/live and the admin gate share.

Everything under /admin is gated before routing, so a caller who is not the
owner learns nothing about which admin paths exist or which methods they take:
401 or 403 for all of it, the same as functions/admin/_middleware.js gating the
whole directory. The Worker also receives /admin/ itself, whose page is not
served here.

A handler answers (status, body[, headers]). A dict body is JSON; anything else
is a clip's: bytes, an async iterator of bytes, or None for no body.
"""

from types import SimpleNamespace

from starlette.applications import Starlette
from starlette.middleware import Middleware
from starlette.requests import Request
from starlette.responses import JSONResponse, Response, StreamingResponse
from starlette.routing import Route

from server import admin_day, admin_players, clips, day, guesses, leaderboard, link
from server import live, score
from server.admin_auth import caller, refusal


async def _body(request):
    """The JSON body, or None for one that is absent or will not parse -- which
    every handler meets with the same 400 as a well-formed body saying nothing."""
    try:
        return await request.json()
    except ValueError:
        return None


async def _exists(get_clip, key: str) -> bool:
    # ponytail: a GET whose body is never read, since the seam has no HEAD; add
    # one to the seam if R2 bills the difference.
    return await get_clip(key, {}) is not None


def respond(status: int, body, headers: dict | None = None) -> Response:
    if isinstance(body, dict):
        return JSONResponse(body, status, headers)
    if body is None or isinstance(body, bytes):
        return Response(body, status, headers)
    return StreamingResponse(body, status, headers)


# (path, method, handler). `r` carries what the request resolved to: db,
# get_clip, fetch, params, body (POST only) and who (the gate's admitted caller,
# under /admin/ only).
ROUTES = [
    ("/api/day", "GET", lambda r: day.day(r.db, r.params)),
    ("/api/guesses", "GET", lambda r: guesses.guesses(r.db, r.params)),
    ("/api/leaderboard", "GET", lambda r: leaderboard.leaderboard(r.db, r.params)),
    ("/api/live", "GET", lambda r: live.live(r.fetch)),
    ("/api/score", "POST", lambda r: score.score(r.db, r.body)),
    ("/api/link", "POST", lambda r: link.link(r.db, r.body)),
    ("/api/link/code", "POST", lambda r: link.issue_code(r.db, r.body)),
    ("/api/link/claim", "POST", lambda r: link.claim(r.db, r.body)),
    ("/admin/day", "GET", lambda r: admin_day.preview(r.db, r.who, r.params)),
    (
        "/admin/day",
        "POST",
        lambda r: admin_day.reject(
            r.db, r.who, r.body, lambda key: _exists(r.get_clip, key)
        ),
    ),
    ("/admin/review", "POST", lambda r: admin_day.review(r.db, r.who, r.body)),
    ("/admin/players", "GET", lambda r: admin_players.players(r.db, r.who)),
    (
        "/admin/players",
        "POST",
        lambda r: admin_players.note_player(r.db, r.who, r.body),
    ),
    ("/admin/plays", "GET", lambda r: admin_players.plays(r.db, r.who, r.params)),
    (
        "/admin/board-note",
        "GET",
        lambda r: admin_players.board_note(r.db, r.who, r.params),
    ),
    (
        "/admin/board-note",
        "POST",
        lambda r: admin_players.set_board_note(r.db, r.who, r.params, r.body),
    ),
]

# The clip route answers every method itself, 405 included, as the Function does.
EVERY_METHOD = ["GET", "HEAD", "POST", "PUT", "PATCH", "DELETE", "OPTIONS"]


def make_app(context, fetch) -> Starlette:
    def route(path: str, method: str, handler) -> Route:
        async def endpoint(request):
            db, get_clip, _ = context(request)
            r = SimpleNamespace(
                db=db,
                get_clip=get_clip,
                fetch=fetch,
                params=request.query_params,
                body=await _body(request) if method == "POST" else None,
                who=request.scope.get("state", {}).get("who"),
            )
            return respond(*await handler(r))

        return Route(path, endpoint, methods=[method])

    async def clip(request):
        _, get_clip, _ = context(request)
        return respond(
            *await clips.clip(
                get_clip,
                request.method,
                request.path_params["name"],
                dict(request.headers),
            )
        )

    return Starlette(
        routes=[
            *(route(*r) for r in ROUTES),
            Route("/clips/{name:path}", clip, methods=EVERY_METHOD),
        ],
        middleware=[Middleware(AdminGate, context=context, fetch=fetch)],
    )


class AdminGate:
    """Asks Twitch who is calling anything under /admin, and answers the
    refusal itself unless it is the owner. The admitted caller rides on the
    scope's state for the handler, which checks it again as its first line."""

    def __init__(self, app, context, fetch):
        self.app, self.context, self.fetch = app, context, fetch

    async def __call__(self, scope, receive, send):
        path = scope.get("path", "")
        if scope["type"] == "http" and (path == "/admin" or path.startswith("/admin/")):
            request = Request(scope)
            _, _, admins = self.context(request)
            who = await caller(request.headers.get("authorization"), self.fetch, admins)
            if refused := refusal(who):
                return await respond(*refused)(scope, receive, send)
            scope.setdefault("state", {})["who"] = who
        await self.app(scope, receive, send)
