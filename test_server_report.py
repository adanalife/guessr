#!/usr/bin/env python3
"""Cover /api/report against the real migrations: who may report a round, how
often, and what the message says.

Each of these fails silently in production. The gate is all that stands
between the endpoint and an open Discord webhook, and it fails *open* -- a
report from someone with no play just posts a message that looks real. The
once-only claim has the same shape, and the tier label is the one word that
tells a staging test from a player.
"""

import asyncio
import json

from server.db import Sqlite
from server.report import report

DATE, MINE, THEIRS, ME, THEM = (
    "2026-09-17",
    "clips/mine-010000.mp4",
    "clips/theirs-020000.mp4",
    "player-me",
    "player-them",
)
DISCORD = ("https://discord.test/hook", "stage-1")


async def seeded() -> Sqlite:
    db = Sqlite().migrate()
    for img in (MINE, THEIRS):
        await db.execute(
            "INSERT INTO answers (image, lat, lng, state, filmed) VALUES (?, 34, -118, 'CA', '2018-03-20')",
            img,
        )
    await db.execute(
        "INSERT INTO rounds (image, median_km, mean_cos, batch, slug, source_ts_sec, clip_ts_sec, radius_m)"
        " VALUES (?, 8, 0.1, 'b1', 'van-day-12', 431.5, 431.5, 90)",
        MINE,
    )
    await db.execute(
        "INSERT INTO round_days (date, position, image) VALUES (?, 3, ?)", DATE, MINE
    )
    for player, img in ((ME, MINE), (THEM, THEIRS)):
        await db.execute(
            "INSERT INTO plays (date, player_id, image, km, points, guess_lat, guess_lng)"
            " VALUES (?, ?, ?, 42.0, 3100, 41.8781, -87.6298)",
            DATE,
            player,
            img,
        )
    return db


def webhook(status=204):
    """A fetch that remembers what it was sent: the message is the product."""
    sent = []

    async def fetch(url, headers=None, method="GET", body=None):
        sent.append((url, method, json.loads(body)["content"]))
        return status, ""

    return fetch, sent


async def reported_at(db, player):
    row = await db.fetchone("SELECT reported_at FROM plays WHERE player_id = ?", player)
    return row["reported_at"]


async def test_report() -> None:
    db = await seeded()
    fetch, sent = webhook()

    status, body = await report(
        db, {"date": DATE, "player_id": ME, "image": MINE}, DISCORD, fetch
    )
    assert (status, body) == (200, {"reported": True}), (status, body)
    assert len(sent) == 1 and sent[0][:2] == (DISCORD[0], "POST"), sent
    content = sent[0][2]
    for want in (
        "**[stage-1]",
        "van-day-12",
        "432s",
        "round 3",
        "41.8781, -87.6298",
        "42 km",
    ):
        assert want in content, (want, content)
    assert content.startswith("**[stage-1]"), content

    # Once: a second press reads as success and posts nothing.
    again = await report(
        db, {"date": DATE, "player_id": ME, "image": MINE}, DISCORD, fetch
    )
    assert again == (200, {"reported": True, "already": True}), again
    assert len(sent) == 1, sent

    for body in (
        {"date": DATE, "player_id": ME, "image": THEIRS},
        {"date": DATE, "player_id": "player-nobody", "image": MINE},
        {"date": "2026-09-16", "player_id": ME, "image": MINE},
    ):
        status, _ = await report(db, body, DISCORD, fetch)
        assert status == 403, body
    assert len(sent) == 1, "a refused report reached the webhook"

    # The wrong shape is a 400, never "not yours".
    for body in (
        None,
        [],
        {},
        {"date": DATE, "player_id": ME},
        {"date": "today", "player_id": ME, "image": MINE},
        {"date": DATE, "player_id": "", "image": MINE},
        {"date": DATE, "player_id": ME, "image": 42},
    ):
        status, _ = await report(db, body, DISCORD, fetch)
        assert status == 400, body


async def test_undeliverable() -> None:
    # No webhook on this tier: refused before the claim, so the player's one
    # report survives until one is set.
    db = await seeded()
    fetch, sent = webhook()
    status, _ = await report(
        db, {"date": DATE, "player_id": THEM, "image": THEIRS}, None, fetch
    )
    assert status == 503 and not sent
    assert await reported_at(db, THEM) is None

    # Discord refused it, or never answered: the claim is given back.
    for fetch in (webhook(500)[0], None):
        if fetch is None:

            async def fetch(*_a, **_k):
                raise OSError("no route")

        status, _ = await report(
            db, {"date": DATE, "player_id": ME, "image": MINE}, DISCORD, fetch
        )
        assert status == 502, status
        assert await reported_at(db, ME) is None, (
            "a failed delivery left the play unreportable"
        )


async def test_no_provenance() -> None:
    # A play whose round predates `rounds` still reports, saying so.
    db = await seeded()
    fetch, sent = webhook()
    status, _ = await report(
        db, {"date": DATE, "player_id": THEM, "image": THEIRS}, DISCORD, fetch
    )
    assert status == 200
    assert (
        "no provenance on record" in sent[0][2] and "round unscheduled" in sent[0][2]
    ), sent


asyncio.run(test_report())
asyncio.run(test_undeliverable())
asyncio.run(test_no_provenance())
print(
    "ok: /api/report forwards a player's own play once, naming the tier and the moment"
)
