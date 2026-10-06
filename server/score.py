"""POST /api/score -- the only place a guess becomes points, and the only place
the true coordinates live. The answers reach a client only after it commits a
guess.

A guess that names a date is a daily play: checked against that date's window and
schedule, then recorded once in `plays`. A guess with no date is a practice round,
scored and never stored, and only against a round from a day that is over,
because that is all practice ever deals.

Framework-free: the handler takes the parsed JSON body (None when it failed to
parse) and returns (status, body), so whatever serves HTTP is a thin shim.
"""

import math

from server import rules


async def score(db, body, now=None, client=None) -> tuple[int, dict]:
    """`client` is rules.client_of's bucket for the caller, stored on the play
    and never returned."""
    guess = rules.parse_guess(body)
    if not guess:
        return 400, {"error": "expected {image, lat, lng}"}

    play = rules.parse_play(body)
    if rules.is_play(body) and not play:
        return 400, {"error": "expected {date, player_id}"}

    # 403 rather than 400: well formed, but not a play this endpoint accepts, and
    # the page tells the two apart to know it must not retry. Without both checks
    # any image name a script has seen buys any score on any date.
    if play and not rules.is_open(play["date"], now):
        return 403, {"error": "that day is closed"}
    if play and not await _in_draw(db, play["date"], guess["image"]):
        return 403, {"error": "that round is not in that day's game"}

    answer = await db.fetchone(
        "SELECT lat, lng, state, filmed FROM answers WHERE image = ?", guess["image"]
    )
    if not answer:
        # A round set scores nothing until `task answers:*:push` has run, which is
        # why this is a distinct 404 rather than a 500.
        return 404, {"error": "unknown round"}

    # The response carries the answer, so an undated guess at a round some date has
    # yet to finish would read its truth before any daily guess was committed.
    # Practice only deals rounds from closed dates, so that is all it may score.
    if not play and not await _practiceable(db, guess["image"], now):
        return 403, {"error": "that round is not open to practice"}

    km = rules.haversine_km(guess, answer)
    scored = {"km": km, "points": rules.score_for(km)}
    reveal = await nearest_reveal(db, guess)
    if not play:
        return 200, {**scored, **answer, "reveal": reveal, "recorded": False}

    # The truth goes back either way: a replay already committed a guess for this
    # round once, and the page needs it to draw the map.
    return 200, {
        **await _record(db, play, guess, scored, client),
        **answer,
        "reveal": reveal,
        "recorded": True,
        **await streak(db, play["player_id"]),
    }


# A finished day is one with a play for every round. Subtracting each finished
# date's rank from its day number gives every date in an unbroken run the same
# value, so the run ending on the latest finished date is the rows sharing its
# value. julianday() counts real days, so a run crosses a month or a year.
STREAK = """
  WITH done AS (
    SELECT date, julianday(date) - ROW_NUMBER() OVER (ORDER BY date) AS run
      FROM plays
     WHERE player_id = ?
     GROUP BY date
    HAVING COUNT(*) >= ?)
  SELECT COUNT(*) AS streak, MAX(date) AS streak_date
    FROM done
   WHERE run = (SELECT run FROM done ORDER BY date DESC LIMIT 1)"""


async def streak(db, player: str) -> dict:
    """{streak, streak_date}: how many consecutive days the player has finished,
    counting back from the latest one they finished, and that date (None with
    no finished day). Whether the run is still alive is the client's call,
    since only it knows which date is today for the player."""
    # ponytail: reads every play the player has, once per daily guess; cache it
    # per player and date if a long-time player's history makes that measurable.
    return await db.fetchone(STREAK, player, rules.ROUNDS_PER_GAME)


# How far from a pin the nearest still may be and still be "what your guess looks
# like". Past this the pin is off every road the van drove, and a frame 60 km away
# is a picture of somewhere else.
REVEAL_KM = 25
KM_PER_DEG = 111.2


async def nearest_reveal(db, guess: dict) -> dict | None:
    """The corpus frame nearest the guess, or None when there is none within
    REVEAL_KM. The pin rather than the answer: a still of where the player
    *guessed* tells them nothing about the round.

    A latitude band, a longitude window widened by 1/cos(lat), then the nearest by
    flat-earth distance, which is exact enough to rank points 25 km apart, with
    haversine on the one winner for the number the page shows."""
    d_lat = REVEAL_KM / KM_PER_DEG
    cos = max(math.cos(math.radians(guess["lat"])), 0.01)
    d_lng = d_lat / cos
    # Any failure is no reveal rather than a failed guess: the still is decoration
    # on a score already earned, and a tier whose migrations are behind its deploy
    # has no table to read at all.
    try:
        row = await db.fetchone(
            """SELECT image, lat, lng FROM reveals
               WHERE lat BETWEEN ? AND ? AND lng BETWEEN ? AND ?
               ORDER BY (lat - ?) * (lat - ?) + (lng - ?) * (lng - ?) * ?
               LIMIT 1""",
            guess["lat"] - d_lat,
            guess["lat"] + d_lat,
            guess["lng"] - d_lng,
            guess["lng"] + d_lng,
            guess["lat"],
            guess["lat"],
            guess["lng"],
            guess["lng"],
            cos * cos,
        )
    except Exception:  # noqa: BLE001 -- see above: no reveal, never a failed guess
        return None
    if not row:
        return None
    km = rules.haversine_km(guess, row)
    if km > REVEAL_KM:
        return None
    return {
        "image": f"reveals/{row['image']}",
        "lat": row["lat"],
        "lng": row["lng"],
        "km": km,
    }


async def _in_draw(db, date: str, image: str) -> bool:
    """Whether an image is one of the five that date plays, read straight off the
    schedule the page was handed."""
    row = await db.fetchone(
        "SELECT 1 FROM round_days WHERE date = ? AND image = ?", date, image
    )
    return row is not None


async def _practiceable(db, image: str, now) -> bool:
    """Whether an image is one practice could have dealt: scheduled on a date that
    has closed. The same predicate as /api/day?practice."""
    row = await db.fetchone(
        "SELECT 1 FROM round_days WHERE image = ? AND date <= ?",
        image,
        rules.last_closed_date(now),
    )
    return row is not None


async def _record(db, play: dict, guess: dict, scored: dict, client) -> dict:
    """Writes the play and returns what ended up on record. First write wins, so
    re-scoring a round cannot improve what the board sees. The pin is stored beside
    its distance because a radius cannot be turned back into a point."""
    changed = await db.execute(
        """INSERT INTO plays (date, player_id, image, km, points, handle, guess_lat, guess_lng, client)
           VALUES (?, ?, ?, ?, ?, ?, ?, ?, ?)
           ON CONFLICT (date, player_id, image) DO NOTHING""",
        play["date"],
        play["player_id"],
        guess["image"],
        scored["km"],
        scored["points"],
        play["handle"],
        guess["lat"],
        guess["lng"],
        client,
    )
    if changed:
        return scored
    kept = await db.fetchone(
        "SELECT km, points FROM plays WHERE date = ? AND player_id = ? AND image = ?",
        play["date"],
        play["player_id"],
        guess["image"],
    )
    # A conflict means the row is there, so a miss is a database that changed
    # under the request. Returning the fresh score beats failing the round.
    return kept or scored
