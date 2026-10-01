#!/usr/bin/env python3
"""Cover the Python /api/games and /api/recap: the token both runtimes must mint
identically, the closing gate that keeps a recap from being a spoiler, and the
round trip from a listed game to the recap it links.

The token is checked against a value functions/_recap.mjs produced: a link the
JavaScript made has to open on a tier the Python serves, and a hash that drifted
would still round-trip perfectly through either runtime alone.
"""

import asyncio
import datetime as dt

from server import rules
from server.db import Sqlite
from server.recap import games, recap, token_for

PID = "a3f1c2d4-0000-4000-8000-000000000000"
OTHER = "a3f1c2d4-0000-4000-8000-000000000001"

assert token_for(PID, "2026-08-01") == "0fd050c9fc8c", "drifted from tokenFor()"
assert token_for(PID, "2026-08-02") != token_for(PID, "2026-08-01")
assert token_for(OTHER, "2026-08-01") != token_for(PID, "2026-08-01")


async def main() -> None:
    db = Sqlite().migrate()
    closed = rules.last_closed_date()
    opened = (dt.date.fromisoformat(closed) + dt.timedelta(days=2)).isoformat()
    for i, date in enumerate((closed, opened)):
        image = f"clips/r-00000{i}.mp4"
        await db.execute(
            """INSERT INTO rounds (image, median_km, mean_cos, batch, slug, source_ts_sec,
                                   clip_ts_sec, radius_m)
               VALUES (?, 10, 0.07, 'test', 'slug', 20, 20, 60)""",
            image,
        )
        await db.execute(
            "INSERT INTO answers (image, lat, lng, state, filmed) VALUES (?, 40, -100, 'NE', '2018-06-01')",
            image,
        )
        await db.execute(
            "INSERT INTO round_days (date, position, image) VALUES (?, 1, ?)",
            date,
            image,
        )
        await db.execute(
            """INSERT INTO plays (date, player_id, image, km, points, handle, guess_lat, guess_lng)
               VALUES (?, ?, ?, 12.5, 4000, 'Amber Basin', 40.1, -100.1)""",
            date,
            PID,
            image,
        )

    assert (await games(db, None))[0] == 400
    assert (await games(db, {"player_id": 42}))[0] == 400
    status, body, headers = await games(db, {"player_id": PID})
    assert status == 200 and headers["cache-control"] == "no-store", headers
    listed = {g["date"]: g for g in body["games"]}
    assert listed[closed]["token"] == token_for(PID, closed), listed
    assert listed[opened]["token"] is None, "a day still in play got a share link"
    assert listed[closed]["total"] == 4000 and listed[closed]["rounds"] == 1

    status, shown, _ = await recap(db, {"date": closed, "r": listed[closed]["token"]})
    assert status == 200, shown
    assert shown["name"] == "Amber Basin" and shown["total"] == 4000, shown
    assert shown["rounds"][0]["guess_lat"] == 40.1, shown
    assert PID not in repr(shown), "a recap carried the player id"

    status, refused = await recap(db, {"date": opened, "r": token_for(PID, opened)})
    assert status == 403 and refused["closes"] > 0, refused
    assert (await recap(db, {"date": "nope"}))[0] == 400
    assert (await recap(db, {"date": closed, "r": "0" * 12}))[0] == 404
    assert (await recap(db, {"date": closed, "r": "not-a-token"}))[0] == 404


asyncio.run(main())
print("ok: the Python recap mints the JavaScript's tokens and keeps open days shut")
