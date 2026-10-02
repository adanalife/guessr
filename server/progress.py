"""POST /api/progress {date, player_id} -- the rounds a player has already
played on a date, with what each scored, so a device picks up a day another
device started.

A POST carrying the id rather than a GET naming it in the query string: the id
is the game's one credential, and a URL is logged where a body is not. The
answer coordinates come back because the player saw them at the reveal; the
id is proof it was them.
"""

from server import rules

# In the order the day dealt them, so a client can walk its own round list and
# stop at the first one missing. LEFT JOIN on the schedule: a play whose round
# was swapped out keeps its row, last.
PLAYED = """
  SELECT p.image, p.km, p.points, p.guess_lat, p.guess_lng,
         a.lat, a.lng, a.state, a.filmed
    FROM plays p
    JOIN answers a ON a.image = p.image
    LEFT JOIN round_days rd ON rd.date = p.date AND rd.image = p.image
   WHERE p.date = ? AND p.player_id = ?
   ORDER BY rd.position IS NULL, rd.position"""


async def progress(db, body) -> tuple[int, dict]:
    date = body.get("date") if isinstance(body, dict) else None
    player = body.get("player_id") if isinstance(body, dict) else None
    if not rules.is_calendar_date(date) or not rules.is_player_id(player):
        return 400, {"error": "expected {date, player_id}"}
    rows = await db.fetchall(PLAYED, date, player)
    return 200, {"date": date, "rounds": rows}
