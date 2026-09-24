#!/usr/bin/env python3
"""Cover the Python day review against the real migrations: who may read a day's
answers, what a reject pays and reports, and that a review mark stops being true
when the day changes. The cases test_admin_day.mjs, test_admin_reject.mjs and
test_admin_review.mjs hold the JavaScript to, with the deployment-tier gate
replaced by the Twitch one.
"""

import asyncio
import datetime as dt

from server.admin_auth import Caller
from server.admin_day import preview, reject, review
from server.db import Sqlite

NOW = dt.datetime(2026, 8, 5, 12, tzinfo=dt.UTC)
PAST, OPEN = "2026-08-01", "2026-08-05"
DAY1, DAY2, DAY3 = "2099-06-01", "2099-06-02", "2099-06-03"
OWNER = Caller("owner", "111", "dana")
MOD = Caller("mod", "222", "friend")


def img(date: str, i: int) -> str:
    return f"clips/{date.replace('-', '')}_{i}-0{i}0000.mp4"


def seeded(dates=(DAY1, DAY2, DAY3), answered=None, spares=0) -> Sqlite:
    """Five scheduled rounds per date, positions inserted backwards so reading
    insertion order instead of position is caught. `answered` defaults to every
    date; a date left out is a rounds push whose answers push never ran."""
    d = Sqlite().migrate()
    c = d.conn
    answered = dates if answered is None else answered

    def round_(image, status, n):
        c.execute(
            "INSERT INTO rounds (image, median_km, mean_cos, batch, status, slug, source_ts_sec, "
            "clip_ts_sec, radius_m) VALUES (?, ?, 0.07, 'test', ?, 'slug', 20.5, 20.5, 61.2)",
            (image, n, status),
        )

    for k, date in enumerate(dates):
        for i in range(5, 0, -1):
            round_(img(date, i), "scheduled", 10 * i + k)
            c.execute(
                "INSERT INTO round_days (date, position, image) VALUES (?, ?, ?)",
                (date, i, img(date, i)),
            )
            if date in answered:
                c.execute(
                    "INSERT INTO answers (image, lat, lng, state, filmed) VALUES (?, ?, ?, 'Indiana', '2018-06-12')",
                    (img(date, i), 41.5 + i, -87.5 - i),
                )
    for i in range(spares):
        round_(f"clips/spare-00000{i}.mp4", "queued", i)
    return d


def schedule(d: Sqlite, date: str) -> list[str]:
    return [
        r[0]
        for r in d.conn.execute(
            "SELECT image FROM round_days WHERE date = ? ORDER BY position", (date,)
        )
    ]


def status_of(d: Sqlite, image: str) -> str:
    return d.conn.execute(
        "SELECT status FROM rounds WHERE image = ?", (image,)
    ).fetchone()[0]


async def everywhere(image):
    return True


async def test_gate() -> None:
    # Every handler turns away nobody (401) and a mod (403, owner-only by
    # default) before reading anything, and a refused write writes nothing.
    d = seeded()
    for who, code in ((None, 401), (MOD, 403)):
        status, body, headers = await preview(d, who, {"date": DAY1}, NOW)
        assert (status, headers["cache-control"]) == (
            code,
            "no-store",
        ) and "rounds" not in body
        assert (await preview(d, who, {"date": "nonsense"}, NOW))[0] == code, (
            "refusal read the date"
        )
        assert (
            await reject(d, who, {"date": DAY1, "image": img(DAY1, 1)}, everywhere, NOW)
        )[0] == code
        assert (await review(d, who, {"date": DAY1, "reviewed": True}, NOW))[0] == code
    assert (
        schedule(d, DAY1)[0] == img(DAY1, 1)
        and status_of(d, img(DAY1, 1)) == "scheduled"
    )
    assert d.conn.execute("SELECT COUNT(*) FROM day_reviews").fetchone()[0] == 0


async def test_preview() -> None:
    d = seeded((PAST, DAY1, DAY2), answered=(PAST, DAY1))
    status, body, headers = await preview(d, OWNER, {"date": DAY1}, NOW)
    assert (status, headers["cache-control"]) == (200, "no-store")
    assert body["date"] == DAY1 and body["open"] is False
    assert [r["position"] for r in body["rounds"]] == [1, 2, 3, 4, 5]
    assert all(
        isinstance(r["lat"], float) and r["state"] and r["slug"] for r in body["rounds"]
    )
    assert (body["scheduled_through"], body["queued"], body["reviewed_at"]) == (
        DAY2,
        0,
        None,
    )
    # Every round with an answer, not the day's five; unanswered ones can't plot.
    assert len(body["pool"]) == 10 and all(p["status"] for p in body["pool"])
    assert (await preview(d, OWNER, {"date": OPEN}, NOW))[0] == 404
    live = seeded((OPEN,))
    assert (await preview(live, OWNER, {"date": OPEN}, NOW))[1]["open"] is True
    assert (await preview(d, OWNER, {"date": PAST}, NOW))[1]["rounds"], (
        "the past did not read"
    )

    # A round whose answer was never pushed shows up, answer missing.
    rounds = (await preview(d, OWNER, {"date": DAY2}, NOW))[1]["rounds"]
    assert len(rounds) == 5 and rounds[0]["lat"] is None

    spare = seeded((DAY1,), spares=3)
    _, body, _ = await preview(spare, OWNER, {"date": DAY1}, NOW)
    assert body["queued"] == 3 and len(body["pool"]) == 5, "undated spares were plotted"

    for bad in (
        {},
        {"date": ""},
        {"date": "2026-8-1"},
        {"date": "tomorrow"},
        {"date": "2026-08-01T00:00"},
    ):
        assert (await preview(d, OWNER, bad, NOW))[0] == 400, bad


async def test_reject() -> None:
    def post(d, body, clips=everywhere):
        return reject(d, OWNER, body, clips, NOW)

    for bad in (
        "not json",
        None,
        {},
        {"date": DAY1},
        {"image": img(DAY1, 1)},
        {"date": "2099-6-1", "image": img(DAY1, 1)},
        {"date": DAY1, "image": 42},
    ):
        assert (await post(seeded(), bad))[0] == 400, bad

    for date in (PAST, OPEN):  # finished and live are both frozen
        d = seeded((date,))
        status, body, _ = await post(d, {"date": date, "image": img(date, 2)})
        assert (
            status == 409
            and "frozen" in body["error"]
            and status_of(d, img(date, 2)) == "scheduled"
        )

    assert (await post(seeded(), {"date": DAY1, "image": img(DAY2, 1)}))[0] == 404

    # Surplus first, and it costs no runway.
    d = seeded(spares=1)
    status, body, _ = await post(d, {"date": DAY1, "image": img(DAY1, 3)})
    assert status == 200 and body == {
        "date": DAY1,
        "position": 3,
        "rejected": img(DAY1, 3),
        "replacement": "clips/spare-000000.mp4",
        "unscheduled_day": None,
    }
    assert (
        schedule(d, DAY1)[2] == "clips/spare-000000.mp4" and len(schedule(d, DAY3)) == 5
    )
    assert (
        status_of(d, img(DAY1, 3)) == "rejected"
        and status_of(d, "clips/spare-000000.mp4") == "scheduled"
    )

    # No surplus: the furthest-out day is given up whole, requeued, and reported.
    d = seeded()
    status, body, _ = await post(d, {"date": DAY1, "image": img(DAY1, 1)})
    assert (status, body["unscheduled_day"], body["replacement"]) == (
        200,
        DAY3,
        img(DAY3, 1),
    )
    assert (
        schedule(d, DAY3) == []
        and len(schedule(d, DAY1)) == 5
        and schedule(d, DAY1)[0] == img(DAY3, 1)
    )
    assert [status_of(d, img(DAY3, i)) for i in range(2, 6)] == ["queued"] * 4
    # ...so the next reject is free, and never brings back the rejected round.
    _, second, _ = await post(d, {"date": DAY1, "image": img(DAY1, 2)})
    assert second["unscheduled_day"] is None and second["replacement"] != img(DAY1, 1)

    # End of the runway: refused, nothing marked.
    d = seeded((DAY1,))
    status, body, _ = await post(d, {"date": DAY1, "image": img(DAY1, 1)})
    assert status == 409 and "no queued rounds" in body["error"]
    assert len(schedule(d, DAY1)) == 5 and status_of(d, img(DAY1, 1)) == "scheduled"

    # A replacement with no media is refused before anything is written.
    async def nowhere(image):
        return False

    d = seeded()
    status, body, _ = await post(d, {"date": DAY1, "image": img(DAY1, 1)}, nowhere)
    assert status == 409 and "black pane" in body["error"]
    assert schedule(d, DAY1)[0] == img(DAY1, 1) and len(schedule(d, DAY3)) == 5
    # No media store at all is not asked.
    assert (await post(seeded(), {"date": DAY1, "image": img(DAY1, 1)}, None))[0] == 200


async def test_review() -> None:
    def mark(d, date):
        return preview(d, OWNER, {"date": date}, NOW)

    d = seeded((PAST, DAY1, DAY2))
    status, body, _ = await review(d, OWNER, {"date": DAY1, "reviewed": True}, NOW)
    assert status == 200 and body["reviewed_at"]
    assert (await mark(d, DAY1))[1]["reviewed_at"] == body["reviewed_at"]
    assert (await review(d, OWNER, {"date": DAY1, "reviewed": True}, NOW))[0] == 200, (
        "a re-review failed"
    )
    assert d.conn.execute("SELECT COUNT(*) FROM day_reviews").fetchone()[0] == 1
    assert (await review(d, OWNER, {"date": DAY1, "reviewed": False}, NOW))[1][
        "reviewed_at"
    ] is None

    assert (await review(d, OWNER, {"date": "2099-12-25", "reviewed": True}, NOW))[
        0
    ] == 404
    for bad in (
        None,
        {},
        {"date": DAY1},
        {"date": DAY1, "reviewed": "yes"},
        {"date": "tomorrow", "reviewed": True},
        {"reviewed": True},
    ):
        assert (await review(d, OWNER, bad, NOW))[0] == 400, bad
    assert (await review(d, OWNER, {"date": PAST, "reviewed": True}, NOW))[0] == 409

    # THE ONE THAT MATTERS: a reject out of a reviewed day takes the review with
    # it, and the day given up to pay for it loses its own.
    d = seeded((DAY1, DAY2))
    await review(d, OWNER, {"date": DAY1, "reviewed": True}, NOW)
    await review(d, OWNER, {"date": DAY2, "reviewed": True}, NOW)
    _, out, _ = await reject(
        d, OWNER, {"date": DAY1, "image": img(DAY1, 3)}, everywhere, NOW
    )
    assert out["unscheduled_day"] == DAY2, "the fixture stopped paying from the tail"
    assert (await mark(d, DAY1))[1]["reviewed_at"] is None, (
        "a rejected-from day still reads reviewed"
    )
    assert (
        d.conn.execute(
            "SELECT COUNT(*) FROM day_reviews WHERE date = ?", (DAY2,)
        ).fetchone()[0]
        == 0
    )


async def main() -> None:
    await test_gate()
    await test_preview()
    await test_reject()
    await test_review()


asyncio.run(main())
print(
    "ok: the Python day review matches the contract the admin day tests hold, behind Twitch"
)
