"""The rules a guess is judged by: the scoring curve, what counts as a guess or a
play, which names a player may wear, and when a date is open.

Pure functions and constants, with no I/O past reading the alias wordlist at
import, so every rule here is testable without a database and without a server. The handlers in this package are the only callers.
"""

import datetime as dt
import json
import math
import re
from pathlib import Path

# GeoGuessr's curve: full marks near-exact, ~0 across the continent. 4500 km is
# roughly the width of the playable area (the lower 48).
MAP_SIZE_KM = 4500
MAX_ROUND_SCORE = 5000
# How many rounds a game is. Must agree with web/daily.js.
ROUNDS_PER_GAME = 5

# The date a round set is scheduled on, YYYY-MM-DD. ASCII digits only: Python's
# \d also matches Arabic-Indic and every other script's digits.
DATE = re.compile(r"[0-9]{4}-[0-9]{2}-[0-9]{2}")
# The month a monthly board covers, YYYY-MM. Unlike DATE this is the whole check:
# every month it matches is one the calendar has.
MONTH = re.compile(r"[0-9]{4}-(0[1-9]|1[0-2])")

# The handle is a display label, never an identity: two players called "Jason"
# are two rows keyed on different player_ids that happen to render the same
# string.
MAX_HANDLE = 24

# The two lists a player's alias is drawn from, loaded from web/alias.json, the
# file the page and the Pages Functions import too. This copy is the boundary
# /api/score enforces. A Python Worker bundles only its own modules, so a deploy
# of this package has to ship that file beside them.
_WORDS = json.loads(
    (Path(__file__).resolve().parent.parent / "web" / "alias.json").read_text()
)
ADJECTIVES = frozenset(_WORDS["adjectives"])
NOUNS = frozenset(_WORDS["nouns"])

# When a date is open to play: from midnight in the earliest timezone on Earth
# (UTC+14, 10:00 UTC the day before) to midnight in the latest (UTC-12, 12:00 UTC
# the day after). Must agree with web/daily.js, or the page offers plays this
# refuses.
OPENS_UTC_HOUR = 10
CLOSES_UTC_HOUR = 12


def haversine_km(a: dict, b: dict) -> float:
    r = 6371
    lat1, lat2 = math.radians(a["lat"]), math.radians(b["lat"])
    d_lat = lat2 - lat1
    d_lng = math.radians(b["lng"] - a["lng"])
    h = (
        math.sin(d_lat / 2) ** 2
        + math.cos(lat1) * math.cos(lat2) * math.sin(d_lng / 2) ** 2
    )
    return 2 * r * math.asin(math.sqrt(h))


def score_for(km: float) -> int:
    # floor(x + 0.5), not round(): JavaScript's Math.round rounds halves up and
    # Python's round() rounds them to even, and a score must not depend on which
    # runtime served it.
    return math.floor(MAX_ROUND_SCORE * math.exp(-10 * km / MAP_SIZE_KM) + 0.5)


def _coordinate(value, bound: float) -> bool:
    # bool is an int in Python, and `true` is not a latitude.
    if isinstance(value, bool) or not isinstance(value, (int, float)):
        return False
    return math.isfinite(value) and -bound <= value <= bound


def parse_guess(body) -> dict | None:
    """The one place untrusted input enters the game, so it rejects rather than
    coerces: a string or null latitude has to be a 400, not a NaN that scores."""
    if not isinstance(body, dict):
        return None
    image, lat, lng = body.get("image"), body.get("lat"), body.get("lng")
    if not isinstance(image, str) or not image or len(image) > 200:
        return None
    if not _coordinate(lat, 90) or not _coordinate(lng, 180):
        return None
    return {"image": image, "lat": lat, "lng": lng}


def is_play(body) -> bool:
    """Whether a guess means to be recorded. Kept apart from parse_play so that a
    play that is malformed is a 400 rather than a silent practice round."""
    return isinstance(body, dict) and "date" in body


def is_player_id(value) -> bool:
    """A player id is opaque and client-minted, and it is the only credential the
    game has: a bounded, non-empty string."""
    return isinstance(value, str) and 0 < len(value) <= 64


def is_alias(name) -> bool:
    # Exactly one space, so "Lucky Overpass Foo" does not pass on its first two
    # words.
    if not isinstance(name, str):
        return False
    parts = name.split(" ")
    return len(parts) == 2 and parts[0] in ADJECTIVES and parts[1] in NOUNS


def is_calendar_date(value) -> bool:
    if not isinstance(value, str) or not DATE.fullmatch(value):
        return False
    try:
        dt.date.fromisoformat(value)
    except ValueError:
        return False
    return True


def parse_play(body) -> dict | None:
    if not is_play(body):
        return None
    date, player_id, handle = body["date"], body.get("player_id"), body.get("handle")
    if not is_calendar_date(date) or not is_player_id(player_id):
        return None
    # Absent is legal: a play belongs on the board without a name.
    if handle is not None and not isinstance(handle, str):
        return None
    label = (handle or "").strip()
    # A name the wordlist could not have produced is dropped, not rejected: the
    # score was earned, but an arbitrary string must never reach a board that
    # renders to a live broadcast.
    return {
        "date": date,
        "player_id": player_id,
        "handle": label if is_alias(label) else None,
    }


def play_window(date: str) -> tuple[dt.datetime, dt.datetime]:
    midnight = dt.datetime.fromisoformat(date).replace(tzinfo=dt.UTC)
    return (
        midnight - dt.timedelta(days=1) + dt.timedelta(hours=OPENS_UTC_HOUR),
        midnight + dt.timedelta(days=1) + dt.timedelta(hours=CLOSES_UTC_HOUR),
    )


def is_open(date: str, now: dt.datetime | None = None) -> bool:
    opens, closes = play_window(date)
    return opens <= (now or dt.datetime.now(dt.UTC)) < closes


def last_closed_date(now: dt.datetime | None = None) -> str:
    """The most recent date whose board can no longer change. Date D closes at
    D+1 12:00 UTC, so it is the UTC date 36 hours back."""
    return (
        ((now or dt.datetime.now(dt.UTC)) - dt.timedelta(hours=36)).date().isoformat()
    )


def month_of(now: dt.datetime | None = None) -> str:
    """The month a monthly board covers. A running total needs no closing rule,
    so today's plays belong in it."""
    return (now or dt.datetime.now(dt.UTC)).strftime("%Y-%m")
