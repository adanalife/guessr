"""GET /api/day -- what a date's game is: five rounds, in the order they play.

Image names and nothing else. The easy-to-hard ramp is applied when a date is
scheduled, so the order the rounds arrive in is the ramp; the coordinates live
one table over, and /api/score is the only thing that reads them.

A date the schedule never reached replays a whole finished day instead (see
`rounds_for`), so the game outlives the top-up that feeds it.

`params` is the query string as a mapping; returns (status, body, headers).
"""

import datetime as dt
import hashlib

from server import rules

SCHEDULED = "SELECT image FROM round_days WHERE date = ? ORDER BY position"

# Complete days on or before a cutoff, in a fixed order so the pick is stable.
FULL_DAYS = """SELECT date FROM round_days WHERE date <= ?
                GROUP BY date HAVING COUNT(*) = ? ORDER BY date"""

# How far back a replay reaches: a year-old day while there is one, else any
# day already closed by the time the replaying date opens -- D-3 closes at
# D-2 12:00 UTC, before D opens at D-1 10:00.
REPLAY_BACK_DAYS = (365, 3)


async def rounds_for(db, date: str) -> list[dict]:
    """The date's scheduled rounds or, with none, a replay of one finished day.

    Computed rather than stored, so a dead top-up still leaves a game: it needs
    only what already aired, whose clips and answers are never deleted. A pure
    function of the date and of days frozen before it opened, so every request
    for the date -- /api/day, /api/score, any isolate -- gets the same five."""
    rounds = await db.fetchall(SCHEDULED, date)
    if rounds:
        return rounds
    d = dt.date.fromisoformat(date)
    for back in REPLAY_BACK_DAYS:
        cutoff = (d - dt.timedelta(days=back)).isoformat()
        days = await db.fetchall(FULL_DAYS, cutoff, rules.ROUNDS_PER_GAME)
        if days:
            pick = int(hashlib.sha256(date.encode()).hexdigest(), 16) % len(days)
            return await db.fetchall(SCHEDULED, days[pick]["date"])
    return []


async def day(db, params, now=None) -> tuple[int, dict, dict]:
    if "practice" in params:
        return await _practice(db, now)

    # Stricter than the shape check alone: a date the calendar does not have is
    # a malformed request, not a date that has not opened.
    date = params.get("date")
    if not rules.is_calendar_date(date):
        return 400, {"error": "expected ?date=YYYY-MM-DD, or ?practice"}, {}

    # The entire gate against reading ahead: the server is the only thing that
    # knows next month's five. Up to three dates are open at once, and everything
    # already closed stays readable so a finished game can be looked at again.
    if not rules.is_open(date, now) and date > rules.last_closed_date(now):
        return 403, {"error": "that day has not opened yet"}, {}

    rounds = await rounds_for(db, date)
    # Nothing scheduled and nothing finished to replay: a date before the game
    # began, which the page and smoke.sh tell apart from asking about tomorrow.
    if not rounds:
        return 404, {"error": "no game is scheduled for that date"}, {}

    # A closed date's five are the record of what was played, so it caches for
    # a day. An open date's can still be swapped until someone plays it, and a
    # cached list would hand that player a round the server no longer scores.
    closed = date <= rules.last_closed_date(now)
    return (
        200,
        {"date": date, "rounds": rounds},
        {"cache-control": "public, max-age=86400" if closed else "no-store"},
    )


async def _practice(db, now) -> tuple[int, dict, dict]:
    """Rounds from days that are over, and only those: every round belongs to some
    date, so drawing over the whole pool would hand out a spoiler."""
    rounds = await db.fetchall(
        "SELECT image FROM round_days WHERE date <= ? ORDER BY random() LIMIT ?",
        rules.last_closed_date(now),
        rules.ROUNDS_PER_GAME,
    )
    if not rounds:
        return 404, {"error": "nothing has finished playing yet"}, {}
    # Fewer than five early on is a shorter game rather than none; no-store,
    # because the point is a different draw every time.
    return 200, {"date": None, "rounds": rounds}, {"cache-control": "no-store"}
