"""GET /api/day -- what a date's game is: five rounds, in the order they play.

Image names and nothing else. The easy-to-hard ramp is applied when a date is
scheduled, so the order the rounds arrive in is the ramp; the coordinates live
one table over, and /api/score is the only thing that reads them.

`params` is the query string as a mapping; returns (status, body, headers).
"""

from server import rules


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

    rounds = await db.fetchall(
        "SELECT image FROM round_days WHERE date = ? ORDER BY position", date
    )
    # Inside the window with no rounds means the schedule ran dry, which the page
    # and smoke.sh both need to tell apart from asking about tomorrow.
    if not rounds:
        return 404, {"error": "no game is scheduled for that date"}, {}

    # A date's five are frozen from the moment it opens -- the generator schedules
    # ahead and the admin writes refuse anything open -- so it caches for a day.
    return (
        200,
        {"date": date, "rounds": rounds},
        {"cache-control": "public, max-age=86400"},
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
