"""POST /api/stats {player_id} -- one player's whole record, boiled down for a
stats page: totals, streaks, averages, the best and worst of it, a histogram
of how far off the guesses land, and the same plays cut by state, by round
position and by month.

A POST carrying the id for the reason /api/progress is one: the id is the
game's one credential, and a URL is logged where a body is not. Everything
here the player has already seen at a reveal, today's rounds included.

One read of the player's plays, summed in Python: a long-time player has a few
thousand rows, and every number below is a different cut of the same ones.
"""

import statistics

from server import rules
from server.gamecenter import longest_streak
from server.score import streak

KM_PER_MILE = 1.609344

# The histogram's upper edges, set in miles because that is how the buckets
# read ("under 5 mi") and served in km like every other distance. The last
# bucket is everything past the last edge.
MISS_EDGES_KM = [m * KM_PER_MILE for m in (5, 50, 200, 500, 1000)]

# In the order played. LEFT JOIN on the schedule: a replayed date has none, and
# its plays still count everywhere but the by-position cut.
PLAYS = """
  SELECT p.date, p.km, p.points, a.state, rd.position
    FROM plays p
    JOIN answers a ON a.image = p.image
    LEFT JOIN round_days rd ON rd.date = p.date AND rd.image = p.image
   WHERE p.player_id = ?
   ORDER BY p.date, p.played_at"""


def _averages(rows: list[dict], key: str) -> list[dict]:
    """Rounds and mean points per value of `key`, skipping rows without one."""
    groups: dict = {}
    for r in rows:
        if r[key] not in (None, ""):
            groups.setdefault(r[key], []).append(r["points"])
    return [
        {key: k, "rounds": len(v), "points": round(sum(v) / len(v))}
        for k, v in groups.items()
    ]


def _round(r: dict) -> dict:
    return {k: r[k] for k in ("date", "km", "points", "state")}


def summary(rows: list[dict]) -> dict:
    """Every number on the page that is a cut of the plays alone."""
    days: dict[str, list[int]] = {}
    for r in rows:
        days.setdefault(r["date"], []).append(r["points"])
    finished = {d: sum(p) for d, p in days.items() if len(p) >= rules.ROUNDS_PER_GAME}
    months: dict[str, dict] = {}
    for d, p in days.items():
        m = months.setdefault(d[:7], {"month": d[:7], "points": 0, "games": 0})
        m["points"] += sum(p)
        m["games"] += 1
    misses = [0] * (len(MISS_EDGES_KM) + 1)
    for r in rows:
        misses[sum(r["km"] >= edge for edge in MISS_EDGES_KM)] += 1
    best_day = max(finished, key=finished.get, default=None)
    points = sum(r["points"] for r in rows)
    return {
        "rounds": len(rows),
        "games": len(days),
        "finished": len(finished),
        "first": min(days),
        "points": points,
        "longest": longest_streak(finished),
        "avg_round": round(points / len(rows)),
        "avg_game": round(sum(finished.values()) / len(finished)) if finished else None,
        "median_km": round(statistics.median(r["km"] for r in rows), 1),
        "best_game": best_day and {"date": best_day, "points": finished[best_day]},
        "best_round": _round(min(rows, key=lambda r: r["km"])),
        "worst_round": _round(max(rows, key=lambda r: r["km"])),
        "miss_edges_km": [round(e, 1) for e in MISS_EDGES_KM],
        "misses": misses,
        # Hardest first: the states that fool this player lead.
        "by_state": sorted(
            _averages(rows, "state"), key=lambda s: (s["points"], s["state"])
        ),
        "by_position": sorted(_averages(rows, "position"), key=lambda s: s["position"]),
        "months": [months[m] for m in sorted(months)],
    }


async def stats(db, body) -> tuple[int, dict]:
    player = body.get("player_id") if isinstance(body, dict) else None
    if not rules.is_player_id(player):
        return 400, {"error": "expected {player_id}"}
    rows = await db.fetchall(PLAYS, player)
    if not rows:
        return 200, {"rounds": 0}
    return 200, {**summary(rows), **await streak(db, player)}
