"""GET /api/guesses?board=daily|monthly&rank=N[&date=YYYY-MM-DD|&month=YYYY-MM]
-- the plays behind one board row: which round, how far off, where the pin went.

Keyed by rank rather than player_id, because the id is a write credential and no
public response may carry one. A rank is resolved by re-running the board query,
whose ordering is deterministic, against the same span the board serves.

`params` is the query string as a mapping; returns (status, body, headers).
"""

import re

from server import rules
from server.leaderboard import CACHE, DAILY, MONTHLY, PLACEHOLDER, ROWS, span

RANK = re.compile(r"[0-9]+")

# One player's plays across a span, in the order they were dealt. LEFT JOIN, so a
# play outliving its schedule row loses its number, not the whole row.
#
# The pin, the clip and the round's own coordinates are withheld for a date still
# open, all on the one `?3` test so they cannot drift apart: the monthly board
# sums today, and today's pins and truth are a public copy of the answer key. On
# a closed date nothing here is not already public -- practice reveals a finished
# round's location to anyone. `?3` is the last closed date, which a daily span is
# never past, so the guard only ever bites on the monthly board.
_GUESSES = """
  SELECT p.date, rd.position, p.km, p.points,
         CASE WHEN p.date <= ?3 THEN p.image END AS image,
         CASE WHEN p.date <= ?3 THEN p.guess_lat END AS guess_lat,
         CASE WHEN p.date <= ?3 THEN p.guess_lng END AS guess_lng,
         CASE WHEN p.date <= ?3 THEN a.lat END AS answer_lat,
         CASE WHEN p.date <= ?3 THEN a.lng END AS answer_lng
    FROM plays p
    LEFT JOIN round_days rd ON rd.date = p.date AND rd.image = p.image
    LEFT JOIN answers a ON a.image = p.image
   WHERE p.player_id = ?2 AND p.date {span}
   ORDER BY p.date, rd.position"""
DAILY_GUESSES = _GUESSES.format(span="= ?1")
MONTHLY_GUESSES = _GUESSES.format(span="LIKE ?1 || '-%'")


async def at_rank(db, board: str, params, now=None) -> dict:
    """Which player a board row names, as {row, rank, period, cache} -- or
    {error, status, cache} for a request no board can answer. Kept apart because
    the admin note surface resolves a player exactly this way: two copies of "the
    rank as the LIMIT" would be two answers to "who is #2"."""
    if board not in ("daily", "monthly"):
        return {"error": "board must be daily or monthly", "status": 400}
    raw = params.get("rank") or ""
    rank = int(raw) if RANK.fullmatch(raw) else 0
    if not 1 <= rank <= ROWS:
        return {"error": f"rank must be 1..{ROWS}", "status": 400}

    period, cache, error = span(board, params, now)
    if error:
        return {"error": error, "status": 400}

    # The board with the rank as its LIMIT: the row wanted is the last one, and
    # coming up short is an answer about the board, not a bad request.
    standings = await db.fetchall(DAILY if board == "daily" else MONTHLY, period, rank)
    if len(standings) < rank:
        return {"error": "no player at that rank", "status": 404, "cache": cache}
    return {"row": standings[rank - 1], "rank": rank, "period": period, "cache": cache}


async def guesses(db, params, now=None) -> tuple[int, dict, dict]:
    board = params.get("board") or "daily"
    found = await at_rank(db, board, params, now)
    if "error" in found:
        return found["status"], {"error": found["error"]}, found.get("cache", CACHE)

    rows = await db.fetchall(
        DAILY_GUESSES if board == "daily" else MONTHLY_GUESSES,
        found["period"],
        found["row"]["player_id"],
        rules.last_closed_date(now),
    )
    # The raw name, not the board's collision-numbered one: the caller already
    # holds the label it clicked, and this is a cross-check of who it meant.
    return (
        200,
        {
            "board": board,
            "period": found["period"],
            "rank": found["rank"],
            "name": found["row"]["name"] or PLACEHOLDER,
            "rows": rows,
        },
        found["cache"],
    )
