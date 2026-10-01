#!/usr/bin/env python3
"""Cover /api/gamecenter: the standing is computed from the plays table and
nothing the client sent, each submission carries Apple's required attributes,
a tier with no App Store Connect secrets submits nothing, and the token is a
three-part ES256 JWT over the key the secrets name.

Every one of these fails quietly otherwise: a standing read off the request
body is the cheat the server-side submission exists to rule out, and a token
with the wrong audience is a 401 from Apple that the app never sees.
"""

import asyncio
import base64
import json

from server import gamecenter as gc
from server.asc import AppStoreConnect, from_env
from server.db import Sqlite
from types import SimpleNamespace

PLAYER = "c0ffee00-0000-4000-8000-000000000001"
GAME_PLAYER = "A:_5f21e308073d18f9b3afdc37f646e851"


def play(date, image, km, points):
    return (date, PLAYER, image, km, points)


async def seed(db, plays):
    for i, (date, player, image, km, points) in enumerate(plays):
        await db.execute(
            "INSERT OR IGNORE INTO answers (image, lat, lng, state, filmed) VALUES (?, 0, 0, 'MA', '2018-01-01')",
            image,
        )
        await db.execute(
            "INSERT INTO plays (date, player_id, image, km, points) VALUES (?, ?, ?, ?, ?)",
            date,
            player,
            image,
            km,
            points,
        )


# --- standing ---------------------------------------------------------------

assert gc.standing([], "2026-10") == ({}, {})

rows = [{"date": "2026-10-01", "km": 50, "points": 3000}]
scores, percents = gc.standing(rows, "2026-10")
assert scores == {gc.LIFETIME: 3000, gc.MONTHLY: 3000}, scores
assert percents == {gc.FIRST_PIN: 100, gc.WEEK_STREAK: 14, gc.CENTURY: 1}, percents

# Last month's plays count for life, not for the month.
scores, _ = gc.standing(rows, "2026-11")
assert scores == {gc.LIFETIME: 3000}, scores

# A bullseye is under BULLSEYE_KM; at it is not.
assert gc.BULLSEYE in gc.standing([{**rows[0], "km": 9.9}], "2026-10")[1]
assert gc.BULLSEYE not in gc.standing([{**rows[0], "km": 10}], "2026-10")[1]

# A golden day is one date's rounds summing to the threshold, not a lifetime sum.
golden = [{"date": "2026-10-01", "km": 1, "points": 4000} for _ in range(5)]
assert gc.GOLDEN_DAY in gc.standing(golden, "2026-10")[1]
spread = [{"date": f"2026-10-0{i}", "km": 1, "points": 4000} for i in range(1, 6)]
assert gc.GOLDEN_DAY not in gc.standing(spread, "2026-10")[1]

# A streak is consecutive dates; a gap restarts it; multiple rounds a day count once.
assert gc.longest_streak([]) == 0
assert gc.longest_streak(["2026-10-01", "2026-10-01"]) == 1
assert (
    gc.longest_streak(
        ["2026-10-01", "2026-10-02", "2026-10-04", "2026-10-05", "2026-10-06"]
    )
    == 3
)
assert gc.longest_streak(["2026-09-30", "2026-10-01"]) == 2
week = [{"date": f"2026-10-{d:02d}", "km": 1, "points": 1} for d in range(1, 8)]
assert gc.standing(week, "2026-10")[1][gc.WEEK_STREAK] == 100
assert gc.standing(week[:3], "2026-10")[1][gc.WEEK_STREAK] == 42

# The century caps at 100.
assert gc.standing([rows[0]] * 250, "2026-10")[1][gc.CENTURY] == 100

# --- the handler ------------------------------------------------------------

for bad in [
    None,
    {},
    {"player_id": PLAYER},
    {"player_id": PLAYER, "game_player_id": ""},
    {"player_id": PLAYER, "game_player_id": "x" * 65},
    {"player_id": 1, "game_player_id": GAME_PLAYER},
]:
    status, body = asyncio.run(gc.sync(None, bad, None, None))
    assert status == 400 and "error" in body, (bad, status, body)

good = {"player_id": PLAYER, "game_player_id": GAME_PLAYER}

# No secrets: nothing submitted, nothing called, the database not even read.
assert asyncio.run(gc.sync(None, good, None, None)) == (200, {"submitted": []})


class FakeASC:
    def __init__(self, status=201):
        self.status = status
        self.sent = []

    async def submit(self, fetch, resource, attributes):
        self.sent.append((resource, attributes))
        return self.status


async def run(plays, body=good, status=201):
    db = Sqlite().migrate()
    await seed(db, plays)
    asc = FakeASC(status)
    return await gc.sync(db, body, asc, None, now=None), asc.sent


(status, body), sent = asyncio.run(run([play("2026-10-01", "clips/a.mp4", 5, 4800)]))
assert status == 200, body
assert set(body["submitted"]) == {
    gc.LIFETIME,
    gc.FIRST_PIN,
    gc.BULLSEYE,
    gc.WEEK_STREAK,
    gc.CENTURY,
} | ({gc.MONTHLY} if gc.rules.month_of() == "2026-10" else set()), body
assert "failed" not in body
for resource, attrs in sent:
    assert (
        attrs["bundleId"] == gc.BUNDLE_ID and attrs["scopedPlayerId"] == GAME_PLAYER
    ), attrs
    assert attrs["preReleased"] is gc.PRERELEASED
    assert attrs["vendorIdentifier"].startswith(gc.BUNDLE_ID + "."), attrs
lifetime = next(a for r, a in sent if a["vendorIdentifier"] == gc.LIFETIME)
assert lifetime["score"] == "4800" and isinstance(lifetime["score"], str), lifetime
assert (
    next(r for r, a in sent if a["vendorIdentifier"] == gc.LIFETIME)
    == "gameCenterLeaderboardEntrySubmissions"
)
assert (
    next(r for r, a in sent if a["vendorIdentifier"] == gc.FIRST_PIN)
    == "gameCenterPlayerAchievementSubmissions"
)

# The standing is the table's, whatever the body says: a stranger's plays never
# reach this player's submission, and a body naming a score is ignored.
(status, body), sent = asyncio.run(
    run(
        [("2026-10-01", "someone-else", "clips/a.mp4", 1, 5000)],
        body={**good, "score": 999999},
    )
)
assert body == {"submitted": []} and sent == [], (body, sent)

# A refusal from Apple is reported per vendor, and the rest still go.
(status, body), sent = asyncio.run(
    run([play("2026-10-01", "clips/a.mp4", 500, 1500)], status=409)
)
assert status == 200 and body["submitted"] == [] and gc.LIFETIME in body["failed"], body
assert body["failed"][gc.LIFETIME] == 409

# --- the token --------------------------------------------------------------

signed = []


async def fake_sign(pem, data):
    signed.append((pem, data))
    return b"\x01" * 64


# The key is opaque to token(): it only ever reaches sign(), so a stand-in does.
asc = AppStoreConnect("KEY1", "issuer-1", "the-p8-pem", fake_sign)
token = asyncio.run(asc.token(now=1_700_000_000))
parts = token.split(".")
assert len(parts) == 3, token


def decode(part):
    return json.loads(base64.urlsafe_b64decode(part + "=" * (-len(part) % 4)))


assert decode(parts[0]) == {"alg": "ES256", "kid": "KEY1", "typ": "JWT"}, decode(
    parts[0]
)
claims = decode(parts[1])
assert claims["iss"] == "issuer-1" and claims["aud"] == "appstoreconnect-v1", claims
assert claims["exp"] - claims["iat"] == 600 and claims["iat"] == 1_700_000_000, claims
# Signed over header.claims, with the key the secrets carry, and no padding in the output.
assert signed == [(asc.private_key, f"{parts[0]}.{parts[1]}".encode())], signed
assert "=" not in token

# submit() posts JSON:API with the bearer token.
posted = []


async def fetch(url, headers, method="GET", body=None):
    posted.append((url, headers, method, json.loads(body)))
    return 201, ""


status = asyncio.run(
    asc.submit(fetch, "gameCenterLeaderboardEntrySubmissions", {"score": "1"})
)
assert status == 201
url, headers, method, body = posted[0]
assert url.endswith("/v1/gameCenterLeaderboardEntrySubmissions") and method == "POST", (
    url
)
assert (
    headers["Authorization"].startswith("Bearer ")
    and headers["Content-Type"] == "application/json"
)
assert body == {
    "data": {
        "type": "gameCenterLeaderboardEntrySubmissions",
        "attributes": {"score": "1"},
    }
}, body

# from_env: all three or nothing, whitespace trimmed.
env = SimpleNamespace(ASC_KEY_ID=" KEY1 ", ASC_ISSUER_ID="iss", ASC_PRIVATE_KEY="pem")
assert from_env(env, fake_sign).key_id == "KEY1"
assert (
    from_env(SimpleNamespace(ASC_KEY_ID="KEY1", ASC_ISSUER_ID="iss"), fake_sign) is None
)
assert (
    from_env(
        SimpleNamespace(ASC_KEY_ID="", ASC_ISSUER_ID="iss", ASC_PRIVATE_KEY="pem"),
        fake_sign,
    )
    is None
)

print("ok: /api/gamecenter submits the table's standing, and only with secrets")
