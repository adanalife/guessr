"""POST /api/games and GET /api/recap -- a player's own finished dailies, and a
shareable view of one of them.

functions/api/games.js, functions/api/recap.js and functions/_recap.mjs carry
the reasoning; this is the same contract. In short: the player id is a
credential, so a share link carries a date-salted, truncated hash of it instead,
and nothing reveals a day's answers until that day is closed everywhere.
"""

import hashlib
import re

from server import rules
from server.leaderboard import PLACEHOLDER, name_expr

# A month of daily games: long enough to find the one worth showing somebody,
# short enough that the response stays a list rather than an archive.
GAMES = 30
TOKEN_BYTES = 6
TOKEN = re.compile(rf"[0-9a-f]{{{TOKEN_BYTES * 2}}}")
# A finished day cannot change, so a recap of one is the same bytes forever bar
# the player's name.
CACHE = {"cache-control": "public, max-age=3600"}


def token_for(player_id: str, date: str) -> str:
    digest = hashlib.sha256(f"{date}:{player_id}".encode()).digest()
    return digest[:TOKEN_BYTES].hex()


def is_closed(date: str, now=None) -> bool:
    """Done being played anywhere on Earth. Not the negation of is_open: a date
    next week is neither, and a recap of it would spoil a game nobody has had."""
    return date <= rules.last_closed_date(now)


async def player_for(db, date: str, token: str) -> str | None:
    # ponytail: linear in that date's players, which is tens; store the token as
    # a column (backfilled from token_for) if a day ever draws thousands.
    if not TOKEN.fullmatch(token):
        return None
    rows = await db.fetchall(
        "SELECT DISTINCT player_id FROM plays WHERE date = ?", date
    )
    for row in rows:
        if token_for(row["player_id"], date) == token:
            return row["player_id"]
    return None


async def games(db, body, now=None) -> tuple:
    player_id = body.get("player_id") if isinstance(body, dict) else None
    if not rules.is_player_id(player_id):
        return 400, {"error": "expected {player_id}"}
    rows = await db.fetchall(
        """SELECT date, SUM(points) AS total, COUNT(*) AS rounds
             FROM plays
            WHERE player_id = ?
            GROUP BY date
            ORDER BY date DESC
            LIMIT ?""",
        player_id,
        GAMES,
    )
    # A token only for a day closed everywhere: a link to one still open is a
    # spoiler for whoever it is sent to.
    listed = [
        {
            **g,
            "token": token_for(player_id, g["date"])
            if is_closed(g["date"], now)
            else None,
        }
        for g in rows
    ]
    return 200, {"games": listed}, {"cache-control": "no-store"}


async def recap(db, params, now=None) -> tuple:
    date, token = params.get("date"), params.get("r") or ""
    if not rules.is_calendar_date(date):
        return 400, {"error": "expected ?date=YYYY-MM-DD&r=<token>"}
    if not is_closed(date, now):
        # Milliseconds, as the page's playWindow() counts them.
        closes = rules.play_window(date)[1]
        return 403, {
            "error": "that day is still being played",
            "closes": int(closes.timestamp() * 1000),
        }

    player_id = await player_for(db, date, token)
    if not player_id:
        return 404, {"error": "no game found for that link"}

    # In the order they were played; the inner join to plays drops rounds this
    # player never answered.
    rounds = await db.fetchall(
        """SELECT d.image, a.lat, a.lng, a.state, a.filmed,
                  p.km, p.points, p.guess_lat, p.guess_lng
             FROM round_days d
             JOIN plays p ON p.date = d.date AND p.image = d.image AND p.player_id = ?
             JOIN answers a ON a.image = d.image
            WHERE d.date = ?
            ORDER BY d.position""",
        player_id,
        date,
    )
    if not rounds:
        return 404, {"error": "that game cannot be rebuilt"}

    named = await db.fetchone(f"SELECT {name_expr('?1')} AS name", player_id)
    return (
        200,
        {
            "date": date,
            "name": (named or {}).get("name") or PLACEHOLDER,
            "total": sum(r["points"] for r in rounds),
            "rounds": rounds,
        },
        CACHE,
    )
