#!/usr/bin/env python3
"""The HTTP contract every route promises, asserted against a running server.

    python3 contract.py <base-url>          # the whole contract, tier "local"
    python3 contract.py <base-url> locked   # /admin/ with no tier stamped
    python3 contract.py <base-url> twitch   # /admin/ to a caller Twitch refuses
    python3 contract.py --seed              # the plays SQL the contract expects

Black-box on purpose: it speaks HTTP and nothing else, so it says nothing about
what language the handlers are written in, and it holds whatever serves them to
the same statuses, shapes and guards. integration.sh is the orchestrator -- it
fabricates the round set, seeds a throwaway local D1 and R2, boots the server and
runs this twice, once before stamping a tier and once after.
integration_uvicorn.py does the same for the Python app under uvicorn.

Every /admin/ request carries `Authorization: Bearer <OWNER_TOKEN>` unless it
names its own. workerd's Access gate never reads it; the Python app's Twitch
gate is what it is for, and integration_uvicorn.py stubs Twitch to answer that
token as the owner.

What it assumes about the database is exactly what integration.sh seeds, and all
of it is keyed on dates relative to today (UTC) so no answer depends on the
hour it runs at:

- fixture.py schedules consecutive dates from FIRST = today - 2. FIRST closed at
  today - 1 12:00 UTC, so it is always a finished day; today is always open;
  today + 2 opens at today + 1 10:00 UTC, so it and everything after it are
  never open yet. That is what the admin writes need, and why the run schedules
  at least six days: the reject takes the furthest day as its replacement.
- `--seed` puts three players' games on FIRST, which is the only way a closed
  date gets plays -- /api/score refuses one, by design.
- The first round of the furthest date has an object in the local bucket, so
  the clip route has something to serve and the reject has a replacement with
  media behind it.

Not named test_*.py, because `task test` globs those and runs them with no
server up. Zero dependencies, like the rest of the suite.
"""

import datetime as dt
import json
import math
import re
import sys
import urllib.error
import urllib.request

UTC = dt.timezone.utc
NOW = dt.datetime.now(UTC)
TODAY = NOW.date()
FIRST = TODAY - dt.timedelta(days=2)
# web/daily.js's lastClosedDate: date D closes at D+1 12:00 UTC.
LAST_CLOSED = (NOW - dt.timedelta(hours=36)).date()
MONTH = NOW.strftime("%Y-%m")

# The seeded board on FIRST. Points are per round, and the two nameless players
# are what the collision numbering is asserted against.
SEEDED = [
    ("c0ffee00-0000-4000-8000-000000000001", 10.0, 3000, "Amber Basin"),
    ("c0ffee00-0000-4000-8000-000000000002", 100.0, 2000, None),
    ("c0ffee00-0000-4000-8000-000000000003", 1000.0, 1000, None),
]
# Two browsers belonging to one player, for /api/link.
PHONE = "a3f1c2d4-0000-4000-8000-00000000000a"
DESKTOP = "a3f1c2d4-0000-4000-8000-00000000000b"


def seed_sql() -> str:
    """Every round FIRST plays, answered by each SEEDED player."""
    rows = ", ".join(
        f"('{pid}', {km}, {points}, {'NULL' if handle is None else repr(handle)})"
        for pid, km, points, handle in SEEDED
    )
    return (
        "INSERT INTO plays (date, player_id, image, km, points, handle, guess_lat, guess_lng)\n"
        "SELECT d.date, p.column1, d.image, p.column2, p.column3, p.column4, 40.0, -100.0\n"
        f"  FROM round_days d, (VALUES {rows}) p\n"
        f" WHERE d.date = '{FIRST}';\n"
    )


BASE = ""
# The token integration_uvicorn.py's Twitch stub knows as the owner's.
OWNER_TOKEN = "contract-owner-token"


class Reply:
    def __init__(self, status, headers, raw):
        self.status, self.headers, self.raw = status, headers, raw

    @property
    def json(self):
        return json.loads(self.raw)

    def header(self, name):
        return self.headers.get(name) or ""


def call(method, path, body=None, headers=None, raw=None) -> Reply:
    data = (
        raw if raw is not None else None if body is None else json.dumps(body).encode()
    )
    req = urllib.request.Request(BASE + path, data=data, method=method)
    if data is not None:
        req.add_header("content-type", "application/json")
    headers = dict(headers or {})
    if path.startswith("/admin") and not any(
        k.lower() == "authorization" for k in headers
    ):
        headers["authorization"] = f"Bearer {OWNER_TOKEN}"
    for k, v in headers.items():
        req.add_header(k, v)
    try:
        with urllib.request.urlopen(req, timeout=30) as res:
            return Reply(res.status, res.headers, res.read())
    except urllib.error.HTTPError as e:
        return Reply(e.code, e.headers, e.read())


def expect(name, status, method, path, body=None, **kw):
    """One request, its status asserted; JSON routes must answer JSON."""
    r = call(method, path, body, **kw)
    assert r.status == status, (
        f"{name}: expected {status}, got {r.status}: {r.raw[:300]!r}"
    )
    if r.raw and r.header("content-type").startswith("application/json"):
        r.json  # parses, or the assertion below names why
    print(f"ok: {name} -> {status}")
    return r


def get(name, status, path, **kw):
    return expect(name, status, "GET", path, **kw)


def post(name, status, path, body=None, **kw):
    return expect(name, status, "POST", path, body, **kw)


def error(r):
    """A refusal is JSON with an `error` string, never the site's HTML."""
    assert r.header("content-type").startswith("application/json"), r.header(
        "content-type"
    )
    assert isinstance(r.json.get("error"), str), r.raw
    return r.json["error"]


def haversine_km(a, b):
    rad = math.radians
    h = (
        math.sin(rad(b[0] - a[0]) / 2) ** 2
        + math.cos(rad(a[0]))
        * math.cos(rad(b[0]))
        * math.sin(rad(b[1] - a[1]) / 2) ** 2
    )
    return 2 * 6371 * math.asin(math.sqrt(h))


def d(offset):
    return (TODAY + dt.timedelta(days=offset)).isoformat()


# -- /admin/ with no tier stamped -------------------------------------------

ADMIN = [
    ("GET", "/admin/"),
    ("GET", f"/admin/day?date={d(2)}"),
    ("POST", "/admin/day"),
    ("POST", "/admin/review"),
    ("GET", f"/admin/plays?date={TODAY}"),
    ("GET", "/admin/players"),
    ("POST", "/admin/players"),
    ("GET", f"/admin/board-note?board=daily&date={FIRST}&rank=1"),
    ("POST", f"/admin/board-note?board=daily&date={FIRST}&rank=1"),
]


def locked():
    """A tier the middleware cannot name is not "local", and with no Access
    application configured it closes every route -- page included -- rather
    than falling through to the handlers. A forged token changes nothing."""
    for method, path in ADMIN:
        for how, headers in (
            ("", {}),
            (" to a forged token", {"cf-access-jwt-assertion": "a.b.c"}),
        ):
            r = expect(
                f"{method} {path} is closed{how}",
                503,
                method,
                path,
                {},
                headers=headers,
            )
            assert "no Access application" in error(r), r.raw
            assert r.header("cache-control") == "no-store", r.header("cache-control")


def twitch():
    """The Python app's gate: with no token, or one Twitch does not vouch for,
    every admin route -- page included -- is refused before it is routed."""
    for method, path in ADMIN:
        for how, token in (("", ""), (" to a stranger's token", "Bearer stranger")):
            r = expect(
                f"{method} {path} is refused{how}",
                401,
                method,
                path,
                {},
                headers={"authorization": token},
            )
            assert error(r) == "sign in with Twitch", r.raw
            assert r.header("cache-control") == "no-store", r.header("cache-control")


# -- the public API ----------------------------------------------------------


def day():
    r = get("today's game is served", 200, f"/api/day?date={TODAY}")
    game = r.json
    assert game["date"] == str(TODAY), game
    assert len(game["rounds"]) == 5, game
    images = [x["image"] for x in game["rounds"]]
    assert len(set(images)) == 5, "a round was served twice in one game"
    # A round reaches the browser as a name and nothing else.
    assert all(list(x) == ["image"] for x in game["rounds"]), game
    assert r.header("cache-control") == "public, max-age=86400", r.header(
        "cache-control"
    )

    first = get("a finished day stays readable", 200, f"/api/day?date={FIRST}").json
    assert len(first["rounds"]) == 5, first

    # The spoiler property: a date that IS scheduled is still refused until it
    # opens. today + 2 is on the schedule and never open yet.
    for offset in (2, 3, 400):
        error(
            get(
                f"an unopened date (today+{offset}) is refused",
                403,
                f"/api/day?date={d(offset)}",
            )
        )
    # Readable-but-empty is a different answer from not-yet-open.
    error(get("a closed date with no game is 404", 404, f"/api/day?date={d(-30)}"))
    for bad in ("nope", "", "2026-9-1"):
        error(get(f"a malformed date {bad!r} is refused", 400, f"/api/day?date={bad}"))
    error(get("no date at all is refused", 400, "/api/day"))

    # Practice draws only from dates that have closed.
    closed = {x["image"] for x in first["rounds"]}
    yesterday = str(TODAY - dt.timedelta(days=1))
    if yesterday <= str(LAST_CLOSED):
        closed |= {
            x["image"]
            for x in get("yesterday reads", 200, f"/api/day?date={yesterday}").json[
                "rounds"
            ]
        }
    r = get("practice draws a game", 200, "/api/day?practice")
    assert r.json["date"] is None, r.json
    drawn = [x["image"] for x in r.json["rounds"]]
    assert drawn and set(drawn) <= closed, (
        f"practice served an unfinished day's round: {drawn}"
    )
    assert r.header("cache-control") == "no-store", r.header("cache-control")
    return images, [x["image"] for x in first["rounds"]]


def score(images, first_images):
    img = images[0]
    # Practice: a finished day's round, scored, never recorded, and the truth
    # comes back to draw.
    r = post(
        "a practice guess scores",
        200,
        "/api/score",
        {"image": first_images[0], "lat": 40, "lng": -100},
    )
    s = r.json
    assert s["recorded"] is False, s
    assert {"km", "points", "lat", "lng", "state", "filmed"} <= set(s), s
    km = haversine_km((40, -100), (s["lat"], s["lng"]))
    assert abs(s["km"] - km) < 0.01, (s, km)
    assert s["points"] == round(5000 * math.exp(-10 * s["km"] / 4500)), s

    # Undated is not a way round the window: today's round, and one not yet open,
    # would otherwise hand their answers to anyone who asks without a date.
    error(
        post(
            "an undated guess at today's round is refused",
            403,
            "/api/score",
            {"image": img, "lat": 40, "lng": -100},
        )
    )
    ahead = get("an unopened day's rounds", 200, f"/admin/day?date={d(2)}").json
    error(
        post(
            "an undated guess at an unopened day's round is refused",
            403,
            "/api/score",
            {"image": ahead["rounds"][0]["image"], "lat": 40, "lng": -100},
        )
    )
    guess = {"image": img, "lat": 40, "lng": -100}
    for name, body in [
        ("an empty body", {}),
        ("a string latitude", {**guess, "lat": "40"}),
        ("a latitude off the globe", {**guess, "lat": 91}),
        ("a longitude off the globe", {**guess, "lng": 181}),
        ("an empty image", {**guess, "image": ""}),
        ("an overlong image", {**guess, "image": "x" * 201}),
        ("a date with no player", {**guess, "date": str(TODAY)}),
        ("the 31st of February", {**guess, "date": "2026-02-31", "player_id": PHONE}),
        ("an overlong player id", {**guess, "date": str(TODAY), "player_id": "x" * 65}),
        (
            "a handle that is not a string",
            {**guess, "date": str(TODAY), "player_id": PHONE, "handle": 5},
        ),
    ]:
        error(post(f"{name} is a 400", 400, "/api/score", body))
    error(post("a body that is not JSON is a 400", 400, "/api/score", raw=b"not json"))

    play = {"lat": 40, "lng": -100, "player_id": PHONE}
    error(
        post(
            "a closed date is refused",
            403,
            "/api/score",
            {**play, "image": first_images[0], "date": str(FIRST)},
        )
    )
    error(
        post(
            "an unopened date is refused",
            403,
            "/api/score",
            {**play, "image": img, "date": "2099-01-01"},
        )
    )
    error(
        post(
            "another date's round is refused",
            403,
            "/api/score",
            {**play, "image": first_images[0], "date": str(TODAY)},
        )
    )
    error(
        post(
            "an unknown round is refused",
            404,
            "/api/score",
            {"image": "clips/not-a-real-round.mp4", "lat": 40, "lng": -100},
        )
    )

    # Daily plays, and first write wins: replaying a round with a better guess
    # answers the score already on record.
    today = {"date": str(TODAY)}
    one = post(
        "a daily play records", 200, "/api/score", {**play, **today, "image": images[0]}
    ).json
    assert one["recorded"] is True, one
    again = post(
        "replaying a round records nothing new",
        200,
        "/api/score",
        {**play, **today, "image": images[0], "lat": one["lat"], "lng": one["lng"]},
    ).json
    assert again["recorded"] is True and (again["km"], again["points"]) == (
        one["km"],
        one["points"],
    ), (one, again)
    post(
        "a second round records",
        200,
        "/api/score",
        {**play, **today, "image": images[1]},
    )
    # The other browser answered round one too, under a name no wordlist made.
    desk = post(
        "another browser's play records",
        200,
        "/api/score",
        {
            **today,
            "image": images[0],
            "lat": 35,
            "lng": -90,
            "player_id": DESKTOP,
            "handle": "<b>not a wordlist name</b>",
        },
    ).json
    return desk


def leaderboard():
    r = get("the daily board reads", 200, "/api/leaderboard?board=daily")
    assert r.json["period"] == str(LAST_CLOSED), r.json
    assert isinstance(r.json["rows"], list)
    assert (
        get("the default board is daily", 200, "/api/leaderboard").json["board"]
        == "daily"
    )

    r = get(
        "a finished day's board reads",
        200,
        f"/api/leaderboard?board=daily&date={FIRST}",
    )
    assert r.json == {
        "board": "daily",
        "period": str(FIRST),
        "rows": [
            ["Amber Basin", 15000],
            ["anonymous (1)", 10000],
            ["anonymous (2)", 5000],
        ],
    }, r.json
    assert r.header("cache-control") == "public, max-age=3600", r.header(
        "cache-control"
    )

    r = get("the monthly board reads", 200, "/api/leaderboard?board=monthly")
    assert r.json["period"] == MONTH and r.json["rows"], r.json
    assert all(isinstance(n, str) and isinstance(p, int) for n, p in r.json["rows"]), (
        r.json
    )
    assert r.header("cache-control") == "public, max-age=60", r.header("cache-control")
    assert (
        get(
            "the running month by name",
            200,
            f"/api/leaderboard?board=monthly&month={MONTH}",
        ).json["period"]
        == MONTH
    )
    # A player id is a write credential, so no board carries one.
    assert b"player_id" not in r.raw and PHONE.encode() not in r.raw, r.raw

    for name, q in [
        ("an unknown board", "board=weekly"),
        ("a month on the daily board", f"board=daily&month={MONTH}"),
        ("a date on the monthly board", f"board=monthly&date={FIRST}"),
        ("a date still open", f"board=daily&date={TODAY}"),
        ("the 31st of February", "board=daily&date=2026-02-31"),
        ("month 13", "board=monthly&month=2026-13"),
        ("a month not yet started", "board=monthly&month=2099-01"),
    ]:
        error(get(f"{name} is refused", 400, f"/api/leaderboard?{q}"))


def guesses():
    r = get(
        "a finished day's drilldown reads",
        200,
        f"/api/guesses?board=daily&date={FIRST}&rank=1",
    )
    g = r.json
    assert (g["board"], g["period"], g["rank"], g["name"]) == (
        "daily",
        str(FIRST),
        1,
        "Amber Basin",
    ), g
    assert [x["position"] for x in g["rows"]] == [1, 2, 3, 4, 5], g
    for row in g["rows"]:
        assert row["points"] == 3000 and row["image"] and row["guess_lat"] == 40.0, row
        assert row["answer_lat"] is not None and row["answer_lng"] is not None, row
    assert b"player_id" not in r.raw, r.raw
    assert (
        get(
            "an unnamed player is the placeholder",
            200,
            f"/api/guesses?board=daily&date={FIRST}&rank=2",
        ).json["name"]
        == "anonymous"
    )

    error(
        get(
            "a rank nobody holds is 404",
            404,
            f"/api/guesses?board=daily&date={FIRST}&rank=4",
        )
    )
    for name, q in [
        ("an open date", f"board=daily&date={TODAY}&rank=1"),
        ("rank 0", f"board=daily&date={FIRST}&rank=0"),
        ("rank 11", f"board=daily&date={FIRST}&rank=11"),
        ("no rank", f"board=daily&date={FIRST}"),
        ("an unknown board", "board=weekly&rank=1"),
    ]:
        error(get(f"a drilldown on {name} is refused", 400, f"/api/guesses?{q}"))

    # The monthly board sums today, which is still open, so a row on an open
    # date carries its distance and points and none of the pin, clip or truth.
    rank, withheld = 1, 0
    while True:
        r = call("GET", f"/api/guesses?board=monthly&rank={rank}")
        if r.status == 404:
            break
        assert r.status == 200, r.raw
        for row in r.json["rows"]:
            hidden = row["date"] > str(LAST_CLOSED)
            for key in ("image", "guess_lat", "guess_lng", "answer_lat", "answer_lng"):
                assert (row[key] is None) == hidden, (key, row)
            withheld += hidden
        rank += 1
    assert withheld, "no open-date row reached the monthly drilldown to check"
    print(
        f"ok: the monthly drilldown withholds {withheld} open-date pins across {rank - 1} ranks"
    )


def live():
    # The upstream is YouTube's feed, which may be unreachable from here; the
    # contract is the shape and the degradation, not a particular video.
    r = get("the live resolver answers", 200, "/api/live")
    body = r.json
    assert set(body) == {"videoId", "why"}, body
    vid = body["videoId"]
    assert vid is None or re.fullmatch(r"[\w-]{11}", vid), body
    landed = "bytes" in body["why"]
    ttl = 300 if landed else 30
    assert r.header("cache-control") == f"public, max-age={ttl}", (
        r.header("cache-control"),
        body,
    )
    if not landed:
        assert body["why"].get("attempts") == 2, body


def clips(image):
    r = get("a clip is served", 200, "/" + image)
    assert r.header("content-type") == "video/mp4", r.header("content-type")
    assert r.header("accept-ranges") == "bytes", r.header("accept-ranges")
    assert r.header("cache-control") == "public, max-age=31536000, immutable", r.header(
        "cache-control"
    )
    assert r.header("etag"), "no etag"
    body = r.raw
    part = get(
        "a clip serves a range", 206, "/" + image, headers={"range": "bytes=0-3"}
    )
    assert part.raw == body[:4], part.raw
    assert part.header("content-range") == f"bytes 0-3/{len(body)}", part.header(
        "content-range"
    )
    get(
        "an unchanged clip is 304",
        304,
        "/" + image,
        headers={"if-none-match": r.header("etag")},
    )
    head = expect("HEAD serves the clip's headers", 200, "HEAD", "/" + image)
    assert head.header("content-type") == "video/mp4" and head.raw == b"", head.raw
    # A real 404, not the site's HTML at 200.
    for path in ("/clips/2018_0101_999999_000_opt-999000.mp4", "/clips/not-a-clip.txt"):
        r = get(f"{path} is a bare 404", 404, path)
        assert not r.header("content-type").startswith("text/html"), r.header(
            "content-type"
        )
    r = post("a POST to a clip is 405", 405, "/" + image)
    assert r.header("allow") == "GET, HEAD", r.header("allow")


def link(desk):
    error(post("a link with one id is refused", 400, "/api/link", {"from": PHONE}))
    error(
        post(
            "a link with an overlong id is refused",
            400,
            "/api/link",
            {"from": "x" * 65, "to": DESKTOP},
        )
    )
    error(post("a link that is not JSON is refused", 400, "/api/link", raw=b"nope"))
    assert post(
        "linking a browser to itself moves nothing",
        200,
        "/api/link",
        {"from": PHONE, "to": PHONE},
    ).json == {"moved": 0}

    # Both browsers answered round one; only the phone answered round two. The
    # collision keeps the desktop's play, so one row moves and none are left.
    r = post("two browsers merge", 200, "/api/link", {"from": PHONE, "to": DESKTOP})
    assert r.json == {"moved": 1}, r.json
    players = {
        p["player_id"]: p
        for p in get("the merge reads back", 200, f"/admin/plays?date={TODAY}").json[
            "players"
        ]
    }
    assert PHONE not in players, "the linked-from id kept its plays"
    merged = players[DESKTOP]
    assert len(merged["rounds"]) == 2, merged
    assert merged["rounds"][0]["points"] == desk["points"], (merged, desk)
    # The handle no wordlist produced was dropped, so the player is unnamed.
    assert merged["name"] is None, merged


def link_codes():
    """After link(), so DESKTOP holds the merged history a code is issued for."""
    error(post("a code with no player id is refused", 400, "/api/link/code", {}))
    error(
        post("a claim with no code is refused", 400, "/api/link/claim", {"from": PHONE})
    )
    error(
        post(
            "a claim of a code nobody issued is 404",
            404,
            "/api/link/claim",
            {"code": "ABCDEFGH", "from": PHONE},
        )
    )
    issued = post(
        "a code is issued", 200, "/api/link/code", {"player_id": DESKTOP}
    ).json
    assert re.fullmatch(r"[A-HJ-NP-Z2-9]{8}", issued["code"]), issued
    assert re.fullmatch(r"\d{4}-\d\d-\d\dT\d\d:\d\d:\d\dZ", issued["expires_at"]), (
        issued
    )
    # The phone has nothing left after link(), so this is a join with nothing to
    # fold in: the answer is who to be.
    claim = {"code": issued["code"].lower(), "from": PHONE}
    r = post("a code is claimed", 200, "/api/link/claim", claim)
    assert r.json == {"player_id": DESKTOP, "moved": 0}, r.json
    error(post("a code claims once", 404, "/api/link/claim", claim))


# -- /admin/ under tier "local" ---------------------------------------------


def admin_reads():
    page = get("the review page is served", 200, "/admin/")
    assert page.header("content-type").startswith("text/html"), page.header(
        "content-type"
    )
    error(get("a preview with no date is refused", 400, "/admin/day"))
    error(
        get(
            "a preview of an unscheduled date is 404", 404, "/admin/day?date=2099-01-01"
        )
    )

    ahead = get(
        "an upcoming day previews with its answers", 200, f"/admin/day?date={d(2)}"
    )
    a = ahead.json
    assert ahead.header("cache-control") == "no-store", ahead.header("cache-control")
    assert a["open"] is False and a["reviewed_at"] is None and a["queued"] == 0, a
    assert [x["position"] for x in a["rounds"]] == [1, 2, 3, 4, 5], a
    for x in a["rounds"]:
        assert {
            "image",
            "median_km",
            "radius_m",
            "slug",
            "source_ts_sec",
            "lat",
            "lng",
            "state",
            "filmed",
        } <= set(x), x
        assert x["lat"] is not None, x
    assert a["pool"] and all({"lat", "lng", "status"} <= set(p) for p in a["pool"]), a[
        "pool"
    ][:2]
    last = a["scheduled_through"]
    assert last >= d(3), (
        f"the run needs a scheduled day past today+2 to reject from; it ends {last}"
    )
    assert (
        get("today previews as open", 200, f"/admin/day?date={TODAY}").json["open"]
        is True
    )

    error(get("a score lookup with no date is refused", 400, "/admin/plays"))
    r = get("a day's plays read", 200, f"/admin/plays?date={FIRST}")
    assert r.header("cache-control") == "no-store"
    ps = r.json["players"]
    assert [p["total"] for p in ps] == [15000, 10000, 5000], ps
    assert all(
        len(p["rounds"]) == 5 and p["rounds"][0]["lat"] is not None for p in ps
    ), ps

    r = get("the player list reads", 200, "/admin/players")
    assert r.header("cache-control") == "no-store"
    ids = {p["player_id"] for p in r.json["players"]}
    assert {pid for pid, *_ in SEEDED} <= ids, ids
    return last


def notes():
    top = SEEDED[0][0]
    for name, body in [
        ("no player", {"note": "x"}),
        ("a note that is not a string", {"player_id": top, "note": 5}),
        ("a note of 501 characters", {"player_id": top, "note": "x" * 501}),
    ]:
        error(
            post(f"a player note with {name} is refused", 400, "/admin/players", body)
        )
    error(
        post(
            "a note for a player who never played is 404",
            404,
            "/admin/players",
            {"player_id": "never-played", "note": "x"},
        )
    )
    assert post(
        "a player note saves",
        200,
        "/admin/players",
        {"player_id": top, "note": "a regular"},
    ).json == {"player_id": top, "note": "a regular"}
    assert (
        post(
            "an empty note clears",
            200,
            "/admin/players",
            {"player_id": top, "note": ""},
        ).json["note"]
        is None
    )

    q = f"/admin/board-note?board=daily&date={FIRST}&rank=1"
    r = get("a board row's note reads", 200, q)
    assert r.json == {
        "board": "daily",
        "period": str(FIRST),
        "rank": 1,
        "name": "Amber Basin",
        "note": None,
    }, r.json
    assert r.header("cache-control") == "no-store"
    assert (
        post("a board row's note saves", 200, q, {"note": "from the board"}).json[
            "note"
        ]
        == "from the board"
    )
    assert get("and reads back", 200, q).json["note"] == "from the board"
    # The same column, whichever surface wrote it.
    by_id = {
        p["player_id"]: p
        for p in get("the player list reads", 200, "/admin/players").json["players"]
    }
    assert by_id[top]["note"] == "from the board" and by_id[top]["alias"] is None, (
        by_id[top]
    )
    error(post("a board note that is not a string is refused", 400, q, {"note": 5}))
    error(
        get(
            "a board note at an empty rank is 404",
            404,
            f"/admin/board-note?board=daily&date={FIRST}&rank=4",
        )
    )
    error(
        get(
            "a board note at rank 0 is refused",
            400,
            f"/admin/board-note?board=daily&date={FIRST}&rank=0",
        )
    )
    error(
        get(
            "a board note on an open date is refused",
            400,
            f"/admin/board-note?board=daily&date={TODAY}&rank=1",
        )
    )


def review():
    for name, body in [
        ("no body", {}),
        ("a non-boolean mark", {"date": d(2), "reviewed": "yes"}),
        ("a malformed date", {"date": "soon", "reviewed": True}),
    ]:
        error(post(f"a review with {name} is refused", 400, "/admin/review", body))
    error(
        post(
            "reviewing an opened date is refused",
            409,
            "/admin/review",
            {"date": str(TODAY), "reviewed": True},
        )
    )
    error(
        post(
            "reviewing an unscheduled date is 404",
            404,
            "/admin/review",
            {"date": "2099-01-01", "reviewed": True},
        )
    )

    marked = post(
        "a day is marked reviewed",
        200,
        "/admin/review",
        {"date": d(2), "reviewed": True},
    ).json
    assert marked["date"] == d(2) and isinstance(marked["reviewed_at"], str), marked
    assert (
        get("the mark reads back", 200, f"/admin/day?date={d(2)}").json["reviewed_at"]
        == marked["reviewed_at"]
    )
    assert (
        post(
            "the mark comes off",
            200,
            "/admin/review",
            {"date": d(2), "reviewed": False},
        ).json["reviewed_at"]
        is None
    )
    post("and goes back on", 200, "/admin/review", {"date": d(2), "reviewed": True})


def reject(last):
    tail = get("the furthest day previews", 200, f"/admin/day?date={last}").json[
        "rounds"
    ]
    ahead = get("the day to reject from previews", 200, f"/admin/day?date={d(2)}").json[
        "rounds"
    ]
    # The furthest day's opener is the one round with media in the local bucket.
    clips(tail[0]["image"])

    for name, body in [
        ("no body", {}),
        ("no image", {"date": d(2)}),
        ("a malformed date", {"date": "soon", "image": ahead[0]["image"]}),
    ]:
        error(post(f"a reject with {name} is refused", 400, "/admin/day", body))
    error(
        post(
            "rejecting from an opened date is refused",
            409,
            "/admin/day",
            {"date": str(TODAY), "image": ahead[0]["image"]},
        )
    )
    error(
        post(
            "rejecting a round the date does not play is 404",
            404,
            "/admin/day",
            {"date": d(2), "image": tail[0]["image"]},
        )
    )
    # Nothing queued and nothing further out: refusing beats emptying the day.
    error(
        post(
            "rejecting from the last day is refused",
            409,
            "/admin/day",
            {"date": last, "image": tail[0]["image"]},
        )
    )

    # With nothing queued, the replacement is paid for out of the furthest day,
    # which is unscheduled whole; the review stops being true in the same write.
    r = post(
        "a round is rejected",
        200,
        "/admin/day",
        {"date": d(2), "image": ahead[2]["image"]},
    ).json
    assert r == {
        "date": d(2),
        "position": 3,
        "rejected": ahead[2]["image"],
        "replacement": tail[0]["image"],
        "unscheduled_day": last,
    }, r
    after = get("the swap reads back", 200, f"/admin/day?date={d(2)}").json
    assert [x["image"] for x in after["rounds"]] == [
        ahead[0]["image"],
        ahead[1]["image"],
        tail[0]["image"],
        ahead[3]["image"],
        ahead[4]["image"],
    ], after
    assert after["reviewed_at"] is None, after
    assert after["queued"] == 4 and after["scheduled_through"] < last, after
    error(get("the given-up day is unscheduled", 404, f"/admin/day?date={last}"))

    # The next replacement comes off the queue, and nothing in the bucket backs it.
    err = error(
        post(
            "a replacement with no media is refused",
            409,
            "/admin/day",
            {"date": d(2), "image": ahead[0]["image"]},
        )
    )
    assert "no media" in err, err


def main() -> int:
    global BASE
    if sys.argv[1:] == ["--seed"]:
        sys.stdout.write(seed_sql())
        return 0
    if len(sys.argv) not in (2, 3) or sys.argv[2:] not in ([], ["locked"], ["twitch"]):
        print(__doc__, file=sys.stderr)
        return 2
    BASE = sys.argv[1].rstrip("/")

    if sys.argv[2:] == ["locked"]:
        locked()
        print("ok: /admin/ is closed on a tier nobody stamped")
        return 0
    if sys.argv[2:] == ["twitch"]:
        twitch()
        print("ok: /admin/ refuses a caller Twitch does not vouch for")
        return 0

    images, first_images = day()
    desk = score(images, first_images)
    leaderboard()
    guesses()
    live()
    link(desk)
    link_codes()
    last = admin_reads()
    notes()
    review()
    reject(last)
    print("ok: every route answers its contract against a real database")
    return 0


if __name__ == "__main__":
    raise SystemExit(main())
