"""GET /api/leaderboard?board=daily[&date=YYYY-MM-DD] | board=monthly[&month=YYYY-MM]
-- the boards, for the Twitch overlay to render.

A read the stream pulls rather than a write the game pushes: the cluster tripbot
runs in has no inbound path, and a leaderboard is not a reason to open one.

`params` is the query string as a mapping; returns (status, body, headers).
"""

from server import rules

# The overlay renders five rows; ten leaves the bot room to filter or re-rank
# without a second request. Also the deepest rank /api/guesses resolves.
ROWS = 10

# A live board changes when a play lands and the bot polls on its own timer, so a
# minute of cache costs nothing. A board asked for by date or by a finished month
# can never change again, so it gets an hour.
CACHE = {"cache-control": "public, max-age=60"}
DATED_CACHE = {"cache-control": "public, max-age=3600"}

# What renders for a play carrying no name. The score still counts and places, so
# a board is never short a row.
PLACEHOLDER = "anonymous"


def name_expr(player: str) -> str:
    """What to call a player, as one SQL expression every query that renders a
    name is built from: an operator alias wins, failing that the last name the
    player drew. `player` is the SQL naming the id -- a column, or a numbered
    parameter, since it appears twice.

    Both halves are point lookups (`players` by primary key, `plays` by
    `plays_by_player_recent`), cheap enough to select per board row.
    `handle IS NOT NULL` so one nameless play does not blank a name the player
    still has; played_at is second-resolution, so rowid breaks a tie by insert
    order."""
    return f"""COALESCE(
    (SELECT n.alias FROM players n WHERE n.player_id = {player}),
    (SELECT h.handle
       FROM plays h
      WHERE h.player_id = {player} AND h.handle IS NOT NULL
      ORDER BY h.played_at DESC, h.rowid DESC
      LIMIT 1))"""


def query(span: str) -> str:
    """Both boards: sum a player's points across a span, best first. The span is
    the only difference -- `= ?` for a day, `LIKE ? || '-%'` for a month. The
    player_id tiebreak is what lets a rank name the same player twice."""
    return f"""
  SELECT p.player_id,
         SUM(p.points) AS points,
         {name_expr("p.player_id")} AS name
    FROM plays p
   WHERE p.date {span}
   GROUP BY p.player_id
   ORDER BY points DESC, p.player_id
   LIMIT ?"""


DAILY = query("= ?")
MONTHLY = query("LIKE ? || '-%'")


def span(board: str, params, now=None) -> tuple[str | None, dict, str | None]:
    """Which span a request asks for, as (period, cache, error). Shared with
    /api/guesses so a drilldown resolves its rank against exactly the board the
    caller is looking at.

    A date at or past the close is refused rather than served: an open date's
    standings reorder while on screen, and refusing is the only way a caller can
    tell "not finished" from "nobody played" (a closed date with empty rows). A
    month has no closing rule; only one that has not started is refused."""
    date, month = params.get("date"), params.get("month")

    if board == "daily":
        if month is not None:
            return None, CACHE, "month applies to the monthly board only"
        if date is None:
            return rules.last_closed_date(now), CACHE, None
        if not rules.is_calendar_date(date):
            return None, CACHE, "date must be YYYY-MM-DD"
        if date > rules.last_closed_date(now):
            return None, CACHE, "date has not closed yet"
        return date, DATED_CACHE, None

    if date is not None:
        return None, CACHE, "date applies to the daily board only"
    running = rules.month_of(now)
    if month is None:
        return running, CACHE, None
    if not rules.MONTH.fullmatch(month):
        return None, CACHE, "month must be YYYY-MM"
    if month > running:
        return None, CACHE, "month has not started yet"
    return month, CACHE if month == running else DATED_CACHE, None


def label(names: list[str]) -> list[str]:
    """Number the players who turn up wearing the same name, in board order, every
    member of a colliding set included -- a lone "(2)" reads as a dropped row. A
    clash belongs to a rendered board, not a play, so it is never stored."""
    totals: dict[str, int] = {}
    for name in names:
        totals[name] = totals.get(name, 0) + 1
    seen: dict[str, int] = {}
    out = []
    for name in names:
        if totals[name] == 1:
            out.append(name)
            continue
        seen[name] = seen.get(name, 0) + 1
        out.append(f"{name} ({seen[name]})")
    return out


async def leaderboard(db, params, now=None) -> tuple[int, dict, dict]:
    board = params.get("board") or "daily"
    if board not in ("daily", "monthly"):
        return 400, {"error": "board must be daily or monthly"}, CACHE

    period, cache, error = span(board, params, now)
    if error:
        return 400, {"error": error}, CACHE

    results = await db.fetchall(DAILY if board == "daily" else MONTHLY, period, ROWS)
    # The placeholder goes on before the numbering, so nameless players are
    # numbered against each other rather than left as identical rows.
    names = label([r["name"] or PLACEHOLDER for r in results])
    rows = [[n, r["points"]] for n, r in zip(names, results, strict=True)]
    return 200, {"board": board, "period": period, "rows": rows}, cache
