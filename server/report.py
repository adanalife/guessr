"""POST /api/report {date, player_id, image} -- a player saying the round they
just played was not where the game says it was.

Someone who recognised the street is a better locator than make_rounds.py, and
a wrong coordinate is otherwise invisible until Dana plays that round himself.
A report is a message, not a record to work through later, so it goes to the
Discord channel the rest of the fleet's reports land in and nothing here queues
it. The one write is `plays.reported_at` (migration 0005), which is the rate
limit: only a play this player recorded can be reported, and only once.

It names the *moment*, not the clip -- `slug` and `source_ts_sec` -- since
ground truth is per-moment and a correction is written against that row.
Scoring is untouched: the score a report disputes stands.

`discord` is `(webhook_url, tier)` for a tier that can deliver, or None, and
`fetch` is the outbound seam app.py shares.
"""

import json

from server import rules

CLAIM = """
  UPDATE plays SET reported_at = datetime('now')
   WHERE date = ? AND player_id = ? AND image = ? AND reported_at IS NULL"""
UNCLAIM = """
  UPDATE plays SET reported_at = NULL
   WHERE date = ? AND player_id = ? AND image = ?"""
PLAYED = "SELECT 1 FROM plays WHERE date = ? AND player_id = ? AND image = ?"

# Resolved from the play, never from what the browser sent: the client names
# which of its own plays it means and nothing else. LEFT, so a play whose round
# predates `rounds` still reports, without provenance.
DETAIL = """
  SELECT p.km, p.guess_lat, p.guess_lng, rd.position, r.slug, r.source_ts_sec
    FROM plays p
    LEFT JOIN round_days rd ON rd.date = p.date AND rd.image = p.image
    LEFT JOIN rounds r ON r.image = p.image
   WHERE p.date = ? AND p.player_id = ? AND p.image = ?"""


def message(tier: str, date: str, image: str, row: dict | None) -> str:
    """Tier first and in bold, because every tier posts to the same channel and
    a staging test would otherwise read as a player's report."""
    row = row or {}
    at = (
        f"`{row['slug']}` at {round(row['source_ts_sec'])}s"
        if row.get("slug")
        else "no provenance on record"
    )
    guess = (
        f"guessed {row['guess_lat']:.4f}, {row['guess_lng']:.4f}"
        if row.get("guess_lat") is not None
        else "pin not recorded"
    )
    where = f"round {row['position']}" if row.get("position") else "round unscheduled"
    return (
        f"**[{tier}] coordinates reported** — {date}, {where}\n"
        f"`{image}` — {at}\n"
        f"{guess}, {round(row.get('km') or 0)} km from the answer"
    )


async def _post(fetch, webhook: str, content: str) -> bool:
    try:
        status, _ = await fetch(
            webhook,
            {"content-type": "application/json"},
            "POST",
            json.dumps({"content": content}),
        )
    except Exception:  # noqa: BLE001 -- no answer and a refusal are one failure to the player
        return False
    return 200 <= status < 300


async def report(db, body, discord, fetch) -> tuple[int, dict]:
    # Before the claim: marking the play first would spend the player's one
    # report on a message no one receives.
    if discord is None:
        return 503, {"error": "reports are not set up here"}

    b = body if isinstance(body, dict) else {}
    date, player, image = b.get("date"), b.get("player_id"), b.get("image")
    if (
        not rules.is_calendar_date(date)
        or not rules.is_player_id(player)
        or not isinstance(image, str)
        or not image
    ):
        return 400, {"error": "expected {date, player_id, image}"}

    # The gate and the dedupe in one statement: a row changes only for a play
    # this player recorded and has not reported yet.
    if not await db.execute(CLAIM, date, player, image):
        if await db.fetchone(PLAYED, date, player, image):
            return 200, {"reported": True, "already": True}
        return 403, {"error": "that round is not one of yours"}

    webhook, tier = discord
    row = await db.fetchone(DETAIL, date, player, image)
    if not await _post(fetch, webhook, message(tier, date, image, row)):
        # Give the claim back, or an outage makes the round unreportable forever.
        await db.execute(UNCLAIM, date, player, image)
        return 502, {"error": "could not pass that on"}
    return 200, {"reported": True}
