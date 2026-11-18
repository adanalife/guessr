"""POST /api/wrapped {player_id, period} -- one player's month (YYYY-MM) or year
(YYYY) in numbers, the read a recap card is drawn from.

A POST for the same reason as /api/progress: the id is the game's one
credential. Everything comes out of `plays`, so a period with no plays answers
zeros and nulls rather than a 404 -- "you didn't play in March" is a recap too.

The span is the monthly board's (`date LIKE ? || '-%'`), so `rank` is the rank
the monthly board would print for a month, and the same ordering summed over
twelve for a year.
"""

import re

from server import rules

PERIOD = re.compile(r"[0-9]{4}(-(0[1-9]|1[0-2]))?")

# A state needs this many rounds before it can be someone's best or worst: one
# lucky pin is not a strength.
STATE_MIN_ROUNDS = 2

TOTALS = """
  SELECT COUNT(DISTINCT date) AS days,
         COUNT(*) AS rounds,
         COALESCE(SUM(points), 0) AS points,
         COALESCE(SUM(km), 0) AS km,
         COALESCE(SUM(points >= ?), 0) AS bullseyes
    FROM plays
   WHERE player_id = ? AND date LIKE ? || '-%'"""


def _extreme(order: str) -> str:
    """The single closest (or furthest) round, earliest first on a tie."""
    return f"""
  SELECT p.date, p.image, p.km, p.points, a.state
    FROM plays p
    JOIN answers a ON a.image = p.image
   WHERE p.player_id = ? AND p.date LIKE ? || '-%'
   ORDER BY p.km {order}, p.date
   LIMIT 1"""


BEST, WORST = _extreme("ASC"), _extreme("DESC")

STATES = """
  SELECT a.state, COUNT(*) AS rounds, AVG(p.km) AS km
    FROM plays p
    JOIN answers a ON a.image = p.image
   WHERE p.player_id = ? AND p.date LIKE ? || '-%'
   GROUP BY a.state
  HAVING COUNT(*) >= ?
   ORDER BY km, a.state"""

# Board order is points, then player_id (leaderboard.query), so a rank counts
# everyone strictly ahead in that order.
RANK = """
  WITH board AS (
    SELECT player_id, SUM(points) AS points
      FROM plays
     WHERE date LIKE ? || '-%'
     GROUP BY player_id)
  SELECT (SELECT COUNT(*) FROM board) AS players,
         (SELECT 1 + COUNT(*)
            FROM board b, board me
           WHERE me.player_id = ?
             AND (b.points > me.points
                  OR (b.points = me.points AND b.player_id < me.player_id))) AS rank"""


async def wrapped(db, body) -> tuple[int, dict]:
    period = body.get("period") if isinstance(body, dict) else None
    player = body.get("player_id") if isinstance(body, dict) else None
    if (
        not isinstance(period, str)
        or not PERIOD.fullmatch(period)
        or not rules.is_player_id(player)
    ):
        return 400, {"error": "expected {player_id, period: YYYY or YYYY-MM}"}

    totals = await db.fetchone(TOTALS, rules.MAX_ROUND_SCORE, player, period)
    rounds = totals["rounds"]
    states = await db.fetchall(STATES, player, period, STATE_MIN_ROUNDS)
    board = await db.fetchone(RANK, period, player)
    return 200, {
        "period": period,
        "days": totals["days"],
        "rounds": rounds,
        "points": totals["points"],
        "km": totals["km"],
        "avg_km": totals["km"] / rounds if rounds else None,
        "bullseyes": totals["bullseyes"],
        "best": await db.fetchone(BEST, player, period) if rounds else None,
        "worst": await db.fetchone(WORST, player, period) if rounds else None,
        # Two qualifying states at least, or best and worst would be one state.
        "best_state": states[0] if len(states) > 1 else None,
        "worst_state": states[-1] if len(states) > 1 else None,
        "rank": board["rank"] if rounds else None,
        "players": board["players"],
    }
