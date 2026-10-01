"""POST /api/gamecenter {player_id, game_player_id} -- the player's Game Center
standing, computed here from `plays` and submitted to Apple from here.

The client never names a score. It says which Game Center player it is signed
in as, and the server submits what the plays table says that guessr player has
earned: the lifetime total, the month's total, and how far along each
achievement is. A modified app can therefore submit nothing the real game did
not record, which is the whole reason the submission is server-side rather than
a `GKLeaderboard.submitScore` in the app.

A tier with no App Store Connect secrets answers `{"submitted": []}` and calls
nobody, which is what stage does.

ponytail: the game player id is taken at its word. A player who learns another's
scoped id could push their own true totals onto them, which only ever moves a
best-score board up. Add GameKit's identity-verification signature if that is
ever a problem.
ponytail: every submission goes every time, seven calls per sync. Keep the last
submitted standing per player if App Store Connect's rate limit bites.
"""

import datetime as dt

from server import rules

BUNDLE_ID = "lol.dana.guessr"
# The app lives on TestFlight, where Game Center runs against the prerelease
# configuration; flip to False when it ships to the App Store.
PRERELEASED = True

# Vendor identifiers, as configured in App Store Connect; app/README.md lists
# what each is.
LIFETIME = f"{BUNDLE_ID}.lifetime"
MONTHLY = f"{BUNDLE_ID}.monthly"
FIRST_PIN = f"{BUNDLE_ID}.first-pin"
BULLSEYE = f"{BUNDLE_ID}.bullseye"
GOLDEN_DAY = f"{BUNDLE_ID}.golden-day"
WEEK_STREAK = f"{BUNDLE_ID}.week-streak"
CENTURY = f"{BUNDLE_ID}.century"

BULLSEYE_KM = 10
# Five rounds at the "success" haptic band (4000) and up.
GOLDEN_DAY_POINTS = 4000 * rules.ROUNDS_PER_GAME
STREAK_DAYS = 7
CENTURY_ROUNDS = 100

MAX_ID = 64


def parse(body) -> dict | None:
    if not isinstance(body, dict):
        return None
    ids = (body.get("player_id"), body.get("game_player_id"))
    if not all(isinstance(v, str) and 0 < len(v) <= MAX_ID for v in ids):
        return None
    return {"player_id": ids[0], "game_player_id": ids[1]}


def longest_streak(dates) -> int:
    """The longest run of consecutive dates among `dates` (ISO strings)."""
    days = sorted({dt.date.fromisoformat(d) for d in dates})
    best = run = 0
    for i, day in enumerate(days):
        run = run + 1 if i and (day - days[i - 1]).days == 1 else 1
        best = max(best, run)
    return best


def standing(rows: list[dict], month: str) -> tuple[dict, dict]:
    """(leaderboard scores, achievement percentages) for one player's plays,
    each row carrying date, km and points. Only what is worth submitting: a
    zero score or a zero percent is left out."""
    by_date: dict[str, int] = {}
    for r in rows:
        by_date[r["date"]] = by_date.get(r["date"], 0) + r["points"]
    scores = {
        LIFETIME: sum(by_date.values()),
        MONTHLY: sum(p for d, p in by_date.items() if d.startswith(month + "-")),
    }
    percents = {
        FIRST_PIN: 100 if rows else 0,
        BULLSEYE: 100 if any(r["km"] < BULLSEYE_KM for r in rows) else 0,
        GOLDEN_DAY: 100 if any(p >= GOLDEN_DAY_POINTS for p in by_date.values()) else 0,
        WEEK_STREAK: min(100, longest_streak(by_date) * 100 // STREAK_DAYS),
        CENTURY: min(100, len(rows) * 100 // CENTURY_ROUNDS),
    }
    return {k: v for k, v in scores.items() if v}, {
        k: v for k, v in percents.items() if v
    }


async def sync(db, body, asc, fetch, now=None) -> tuple[int, dict]:
    """Submits the player's standing and says what Apple accepted."""
    ids = parse(body)
    if not ids:
        return 400, {"error": "expected {player_id, game_player_id}"}
    if asc is None:
        return 200, {"submitted": []}

    rows = await db.fetchall(
        "SELECT date, km, points FROM plays WHERE player_id = ?", ids["player_id"]
    )
    scores, percents = standing(rows, rules.month_of(now))
    base = {
        "bundleId": BUNDLE_ID,
        "scopedPlayerId": ids["game_player_id"],
        "preReleased": PRERELEASED,
    }
    # The score goes as a string, as Apple's own example has it.
    requests = [
        ("gameCenterLeaderboardEntrySubmissions", v, {"score": str(s)})
        for v, s in scores.items()
    ] + [
        ("gameCenterPlayerAchievementSubmissions", v, {"percentageAchieved": p})
        for v, p in percents.items()
    ]
    submitted, failed = [], {}
    for resource, vendor, value in requests:
        status = await asc.submit(
            fetch, resource, {**base, "vendorIdentifier": vendor, **value}
        )
        if status == 201:
            submitted.append(vendor)
        else:
            failed[vendor] = status
    return 200, {"submitted": submitted, **({"failed": failed} if failed else {})}
