"""The day review: look at an upcoming day with its answers, throw a round out of
it, and mark it looked-at.

GET /admin/day is /api/day with both of its rules inverted -- it serves unopened
dates and it serves coordinates -- which is why it is a separate route rather
than a flag on that one. The login in front of it is the only thing standing in
for those rules, so every handler here opens with `refusal`.

Each handler takes the resolved `Caller` (None when nobody signed in) and returns
(status, body, headers).
"""

import datetime as dt

from server import rules
from server.admin_auth import NO_STORE, refusal

# LEFT JOIN on answers: a round scheduled with no answer row is exactly the
# failure this view should show -- a rounds push whose answers push never ran.
ROUNDS = """SELECT d.position, d.image, r.median_km, r.radius_m, r.slug,
                   r.source_ts_sec, a.lat, a.lng, a.state, a.filmed
              FROM round_days d
              JOIN rounds r ON r.image = d.image
              LEFT JOIN answers a ON a.image = d.image
             WHERE d.date = ?
             ORDER BY d.position"""

# How far the schedule reaches and how much spare sits behind it -- either alone
# reads healthy while the other is empty, since a reject with no spares is paid
# for out of the horizon. The count is the one publish.sh reads back.
HORIZON = """SELECT MAX(date) AS date,
                    (SELECT COUNT(*) FROM rounds WHERE status = 'queued') AS queued
               FROM round_days"""

# Every round with an answer, so the page can draw the shape of the pool the day
# came out of. Rides on this response: same gate, nothing new to protect.
POOL = "SELECT a.lat, a.lng, r.status FROM rounds r JOIN answers a ON a.image = r.image"

# A replacement comes from queued surplus first, which costs nothing. With none,
# the furthest-out day is given up whole -- a four-round day is not a day -- and
# its rounds go back to the queue; a generation run buys the runway back.
QUEUED = "SELECT image FROM rounds WHERE status = 'queued' ORDER BY image LIMIT 1"
TAIL = "SELECT MAX(date) AS date FROM round_days"
TAIL_ROUNDS = "SELECT image FROM round_days WHERE date = ? ORDER BY position"
FORGET_REVIEW = "DELETE FROM day_reviews WHERE date = ?"


def _opened(date: str, now: dt.datetime | None) -> bool:
    """Frozen from the moment a date opens: a player mid-game cannot have a round
    swapped under them, and a finished day is the record of what was played.
    Not is_open(), which is false again once a date has closed."""
    return (now or dt.datetime.now(dt.UTC)) >= rules.play_window(date)[0]


async def preview(db, who, params, now=None) -> tuple[int, dict, dict]:
    if refused := refusal(who):
        return refused
    date = params.get("date")
    if not rules.is_calendar_date(date):
        return 400, {"error": "expected ?date=YYYY-MM-DD"}, NO_STORE

    rounds = await db.fetchall(ROUNDS, date)
    if not rounds:
        return 404, {"error": "no game is scheduled for that date"}, NO_STORE

    horizon = await db.fetchone(HORIZON)
    # Null for every day scheduled before reviews existed, which reads the same
    # as a day nobody opened -- which is what it is.
    review = await db.fetchone(
        "SELECT reviewed_at FROM day_reviews WHERE date = ?", date
    )
    return (
        200,
        {
            "date": date,
            "open": rules.is_open(date, now),
            "scheduled_through": horizon["date"],
            "queued": horizon["queued"],
            "reviewed_at": review["reviewed_at"] if review else None,
            "rounds": rounds,
            "pool": await db.fetchall(POOL),
        },
        NO_STORE,
    )


async def reject(db, who, body, clip_exists=None, now=None) -> tuple[int, dict, dict]:
    """POST /admin/day {date, image}: throw a round out and pull its replacement.
    Recorded as `status = 'rejected'` rather than by absence from the schedule,
    so a generation run can tell never-placed from thrown-out.

    `clip_exists` is an async `(key) -> bool` over the media store, or None where
    there is none to ask."""
    if refused := refusal(who):
        return refused
    b = body if isinstance(body, dict) else {}
    date, image = b.get("date"), b.get("image")
    if not rules.is_calendar_date(date) or not isinstance(image, str):
        return 400, {"error": "expected {date, image}"}, NO_STORE
    if _opened(date, now):
        return (
            409,
            {"error": f"{date} has already opened, so its schedule is frozen"},
            NO_STORE,
        )

    slot = await db.fetchone(
        "SELECT position FROM round_days WHERE date = ? AND image = ?", date, image
    )
    if not slot:
        return 404, {"error": f"{image} is not scheduled on {date}"}, NO_STORE

    # Read, decide, then write once. The reads sit outside the transaction
    # because the decision branches; survivable on a surface with one operator.
    replacement = await db.fetchone(QUEUED)
    writes: list[tuple] = []
    unscheduled = None
    if not replacement:
        tail = (await db.fetchone(TAIL))["date"]
        # Nothing further out to borrow from. Refusing beats emptying the day
        # under review; the fix is a generation run.
        if not tail or tail <= date:
            return (
                409,
                {
                    "error": "no queued rounds and nothing scheduled past this date to take one from"
                },
                NO_STORE,
            )
        unscheduled = tail
        replacement = (await db.fetchall(TAIL_ROUNDS, unscheduled))[0]
        writes += [
            (
                "UPDATE rounds SET status = 'queued' "
                "WHERE image IN (SELECT image FROM round_days WHERE date = ?)",
                unscheduled,
            ),
            ("DELETE FROM round_days WHERE date = ?", unscheduled),
            # A day given up entirely has nothing left for its review to describe.
            (FORGET_REVIEW, unscheduled),
        ]

    # A round with no media is a black pane, and this is the only path that
    # schedules a round nobody reviewed -- so it is checked before any write.
    if clip_exists and not await clip_exists(replacement["image"]):
        return (
            409,
            {
                "error": f"{replacement['image']} has no media in the bucket, so it would play as a black pane"
            },
            NO_STORE,
        )

    # One transaction: a half-applied swap leaves a four-round day. The review
    # goes in the same batch, because it described five rounds and one of them is
    # being swapped for a round nobody has looked at. UPDATE in place because
    # round_days is unique on image.
    await db.batch(
        [
            *writes,
            (FORGET_REVIEW, date),
            ("UPDATE rounds SET status = 'rejected' WHERE image = ?", image),
            (
                "UPDATE round_days SET image = ? WHERE date = ? AND position = ?",
                replacement["image"],
                date,
                slot["position"],
            ),
            (
                "UPDATE rounds SET status = 'scheduled' WHERE image = ?",
                replacement["image"],
            ),
        ]
    )
    # The day given up is reported: a reject that silently shortened the horizon
    # reads as free.
    return (
        200,
        {
            "date": date,
            "position": slot["position"],
            "rejected": image,
            "replacement": replacement["image"],
            "unscheduled_day": unscheduled,
        },
        NO_STORE,
    )


async def review(db, who, body, now=None) -> tuple[int, dict, dict]:
    """POST /admin/review {date, reviewed}: mark an upcoming day looked-at, or take
    the mark back. It gates nothing -- review stays possible, never required.
    Its own route rather than a shape on reject, so a payload typo cannot do the
    other thing."""
    if refused := refusal(who):
        return refused
    b = body if isinstance(body, dict) else {}
    date, reviewed = b.get("date"), b.get("reviewed")
    if not rules.is_calendar_date(date) or not isinstance(reviewed, bool):
        return 400, {"error": "expected {date, reviewed}"}, NO_STORE
    # An opened day's schedule could not have been withheld, so marking it would
    # read as approval of something nobody could stop.
    if _opened(date, now):
        return (
            409,
            {"error": f"{date} has already opened, so there is nothing left to review"},
            NO_STORE,
        )
    # A typo'd date would otherwise count toward a horizon nobody looked at.
    if not await db.fetchone("SELECT 1 FROM round_days WHERE date = ? LIMIT 1", date):
        return 404, {"error": f"no game is scheduled for {date}"}, NO_STORE

    if reviewed:
        await db.execute(
            "INSERT INTO day_reviews (date) VALUES (?) "
            "ON CONFLICT (date) DO UPDATE SET reviewed_at = datetime('now')",
            date,
        )
    else:
        await db.execute(FORGET_REVIEW, date)
    # The stored timestamp, so the page shows what the database holds.
    row = await db.fetchone("SELECT reviewed_at FROM day_reviews WHERE date = ?", date)
    return (
        200,
        {"date": date, "reviewed_at": row["reviewed_at"] if row else None},
        NO_STORE,
    )
