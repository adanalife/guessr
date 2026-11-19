"""GET /api/near?lat=N&lng=N[&n=10] -- the finished rounds shot closest to a
point, nearest first, each with the date it was dealt and how the field did.

Closed dates only, on the same `last_closed_date` test /api/guesses withholds
its coordinates by: a finished round's location is already public, since
practice reveals it to anyone, and an open one's is the answer key.

`params` is the query string as a mapping; returns (status, body, headers).
"""

import math

from server import rules
from server.leaderboard import CACHE

DEFAULT, MOST = 10, 50

# Nearest by squared degrees with longitude shrunk by `?4`, cos^2 of the asked
# latitude -- plain arithmetic, so the ordering needs no math functions from the
# database. The plays join runs after the LIMIT, over the rows kept.
NEAR = """
  WITH nearest AS (
    SELECT d.date, d.position, d.image, a.lat, a.lng, a.state, a.filmed,
           (a.lat - ?2) * (a.lat - ?2) + (a.lng - ?3) * (a.lng - ?3) * ?4 AS d2
      FROM round_days d
      JOIN answers a ON a.image = d.image
     WHERE d.date <= ?1
     ORDER BY d2, d.date, d.position
     LIMIT ?5)
  SELECT n.date, n.position, n.image, n.lat, n.lng, n.state, n.filmed,
         COUNT(p.image) AS plays, AVG(p.km) AS avg_km
    FROM nearest n
    LEFT JOIN plays p ON p.date = n.date AND p.image = n.image
   GROUP BY n.date, n.position
   ORDER BY n.d2, n.date, n.position"""


def _number(raw, low: float, high: float) -> float | None:
    """`raw` as a float in [low, high], or None -- which is also what nan and
    the infinities get, since neither compares inside a range."""
    try:
        value = float(raw)
    except (TypeError, ValueError):
        return None
    return value if low <= value <= high else None


async def near(db, params, now=None) -> tuple[int, dict, dict]:
    lat = _number(params.get("lat"), -90, 90)
    lng = _number(params.get("lng"), -180, 180)
    if lat is None or lng is None:
        return 400, {"error": "lat must be -90..90 and lng -180..180"}, CACHE
    raw = params.get("n")
    n = _number(raw, 1, MOST) if raw else DEFAULT
    if n is None or n != int(n):
        return 400, {"error": f"n must be 1..{MOST}"}, CACHE

    rows = await db.fetchall(
        NEAR,
        rules.last_closed_date(now),
        lat,
        lng,
        math.cos(math.radians(lat)) ** 2,
        int(n),
    )
    here = {"lat": lat, "lng": lng}
    for row in rows:
        row["km"] = round(rules.haversine_km(here, row), 1)
        if row["avg_km"] is not None:
            row["avg_km"] = round(row["avg_km"], 1)
    return 200, {"lat": lat, "lng": lng, "rows": rows}, CACHE
