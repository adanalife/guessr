#!/usr/bin/env -S uv run --script --quiet
# /// script
# requires-python = ">=3.13"
# dependencies = ["pyjwt", "cryptography"]
# ///
"""Configure the app's Game Center in App Store Connect: the leaderboards and
achievements server/gamecenter.py submits to, by vendor identifier, each with
its English localization.

    uv run scripts/gamecenter-config.py           # the plan: what is missing
    uv run scripts/gamecenter-config.py --apply   # create it

Idempotent: what exists is read back by vendor identifier and left alone, so
a run after a hand edit in the dashboard only fills gaps. It patches one thing
in place -- a leaderboard whose sort is ascending, since points are better
higher. Images are not uploaded; the dashboard wants one per achievement
before release, and a submission to the prerelease configuration needs none.

Reads ASC_KEY_PATH, ASC_KEY_ID and ASC_ISSUER_ID, as `task ios:release` does.
"""

import datetime
import json
import os
import sys
import time
import urllib.error
import urllib.request

import jwt

API = "https://api.appstoreconnect.apple.com/v1"
BUNDLE_ID = "lol.dana.guessr"
LOCALE = "en-US"


def next_monday() -> str:
    """Midnight UTC of the coming Monday: a recurrence may not start in the
    past, and the weekly board turns over Monday to Monday, which is the week
    server/gamecenter.py sums."""
    today = datetime.datetime.now(datetime.UTC).date()
    monday = today + datetime.timedelta(days=(7 - today.weekday()) % 7 or 7)
    return f"{monday.isoformat()}T00:00:00Z"


# (vendor suffix, reference name, attributes). The weekly board is seven-day
# occurrences, which is what Apple's recurrence allows: at most 30 days, by
# minutes, hours or days, never overlapping -- a calendar month is not
# expressible, which is why the game's monthly board has no Game Center twin.
LEADERBOARDS = [
    ("lifetime", "All Time", {}),
    (
        "weekly",
        "This Week",
        {
            "recurrenceStartDate": next_monday(),
            "recurrenceDuration": "PT168H",
            "recurrenceRule": "FREQ=DAILY;INTERVAL=7",
        },
    ),
]
LEADERBOARD = {
    "defaultFormatter": "INTEGER",
    "submissionType": "BEST_SCORE",
    "scoreSortType": "DESC",
    "visibility": "SHOW_FOR_ALL",
}

# (vendor suffix, name, points, shown before earned, before, after). Points
# sum to Apple's cap of 1000. The two hidden ones are the surprises.
ACHIEVEMENTS = [
    (
        "first-pin",
        "First Pin",
        50,
        True,
        "Play a round.",
        "You played your first round.",
    ),
    (
        "bullseye",
        "Bullseye",
        100,
        True,
        "Put a pin within 10 km of the van.",
        "You put a pin within 10 km of the van.",
    ),
    (
        "golden-day",
        "Golden Day",
        100,
        True,
        "Score 20,000 in a day.",
        "You scored 20,000 in a day.",
    ),
    (
        "week-streak",
        "Seven Days Running",
        100,
        True,
        "Play seven days in a row.",
        "You played seven days in a row.",
    ),
    (
        "century",
        "Century",
        100,
        True,
        "Play a hundred rounds.",
        "You played a hundred rounds.",
    ),
    (
        "perfect-round",
        "Perfect Round",
        150,
        True,
        "Score 5,000 on a round.",
        "You scored a perfect 5,000 on a round.",
    ),
    (
        "perfect-day",
        "Perfect Day",
        250,
        False,
        "Score 5,000 on all five rounds of a day.",
        "Five perfect rounds in one day.",
    ),
    (
        "top-ten",
        "Top Ten",
        150,
        False,
        "Finish a month in the top ten.",
        "You finished a month in the monthly top ten.",
    ),
]


def token() -> str:
    now = int(time.time())
    return jwt.encode(
        {
            "iss": os.environ["ASC_ISSUER_ID"],
            "iat": now,
            "exp": now + 600,
            "aud": "appstoreconnect-v1",
        },
        open(os.environ["ASC_KEY_PATH"]).read(),
        algorithm="ES256",
        headers={"kid": os.environ["ASC_KEY_ID"]},
    )


class Client:
    def __init__(self):
        self.token = token()

    def call(self, method: str, path: str, body: dict | None = None) -> dict:
        req = urllib.request.Request(
            API + path,
            data=json.dumps(body).encode() if body else None,
            method=method,
            headers={
                "Authorization": f"Bearer {self.token}",
                "Content-Type": "application/json",
            },
        )
        try:
            with urllib.request.urlopen(req) as res:
                return json.load(res) if res.status != 204 else {}
        except urllib.error.HTTPError as e:
            sys.exit(f"{method} {path}: {e.code}\n{e.read().decode()[:1500]}")

    def get(self, path: str) -> list[dict]:
        return self.call("GET", path).get("data", [])

    def create(self, kind: str, attributes: dict, relationships: dict) -> dict:
        body = {
            "data": {
                "type": kind,
                "attributes": attributes,
                "relationships": {
                    name: {"data": {"type": type_, "id": id_}}
                    for name, (type_, id_) in relationships.items()
                },
            }
        }
        return self.call("POST", f"/{kind}", body)["data"]


def main() -> int:
    apply = sys.argv[1:] == ["--apply"]
    if sys.argv[1:] not in ([], ["--apply"]):
        sys.exit(__doc__)
    asc = Client()
    app = asc.get(f"/apps?filter[bundleId]={BUNDLE_ID}")
    if not app:
        sys.exit(f"no app with bundle id {BUNDLE_ID}")
    detail = asc.call("GET", f"/apps/{app[0]['id']}/gameCenterDetail")["data"]
    did = detail["id"]
    rel = {"gameCenterDetail": ("gameCenterDetails", did)}

    changes = 0

    def plan(what: str, do) -> None:
        nonlocal changes
        changes += 1
        print(f"{'doing' if apply else 'would'}: {what}")
        if apply:
            do()

    have = {
        lb["attributes"]["vendorIdentifier"]: lb
        for lb in asc.get(f"/gameCenterDetails/{did}/gameCenterLeaderboards")
    }
    for suffix, name, extra in LEADERBOARDS:
        vendor = f"{BUNDLE_ID}.{suffix}"
        lb = have.get(vendor)
        if lb is None:
            attrs = {
                **LEADERBOARD,
                **extra,
                "referenceName": name,
                "vendorIdentifier": vendor,
            }
            lb = plan_create(plan, asc, "gameCenterLeaderboards", attrs, rel, vendor)
        elif lb["attributes"]["scoreSortType"] != "DESC":
            plan(
                f"sort {vendor} descending (it is {lb['attributes']['scoreSortType']})",
                lambda id_=lb["id"]: asc.call(
                    "PATCH",
                    f"/gameCenterLeaderboards/{id_}",
                    {
                        "data": {
                            "type": "gameCenterLeaderboards",
                            "id": id_,
                            "attributes": {"scoreSortType": "DESC"},
                        }
                    },
                ),
            )
        localize(
            plan,
            asc,
            lb,
            "gameCenterLeaderboardLocalizations",
            "gameCenterLeaderboard",
            {"name": name},
        )

    have = {
        a["attributes"]["vendorIdentifier"]: a
        for a in asc.get(f"/gameCenterDetails/{did}/gameCenterAchievements")
    }
    for suffix, name, points, shown, before, after in ACHIEVEMENTS:
        vendor = f"{BUNDLE_ID}.{suffix}"
        a = have.get(vendor)
        if a is None:
            attrs = {
                "referenceName": name,
                "vendorIdentifier": vendor,
                "points": points,
                "showBeforeEarned": shown,
                "repeatable": False,
            }
            a = plan_create(plan, asc, "gameCenterAchievements", attrs, rel, vendor)
        localize(
            plan,
            asc,
            a,
            "gameCenterAchievementLocalizations",
            "gameCenterAchievement",
            {
                "name": name,
                "beforeEarnedDescription": before,
                "afterEarnedDescription": after,
            },
        )

    if not changes:
        print("nothing to do: every leaderboard and achievement is configured")
    elif not apply:
        print(f"{changes} change(s); run again with --apply")
    return 0


def plan_create(
    plan, asc, kind: str, attrs: dict, rel: dict, vendor: str
) -> dict | None:
    """Plans a create and returns the created resource, or None when planning."""
    made = {}
    plan(
        f"create {kind[10:-1].lower()} {vendor}",
        lambda: made.update(asc.create(kind, attrs, rel)),
    )
    return made or None


def localize(
    plan, asc, owner: dict | None, kind: str, relationship: str, attrs: dict
) -> None:
    """Adds the English localization to `owner` when it has none."""
    if owner is None:
        # Not created yet (planning), so its localization is one more step.
        plan(f"localize {attrs['name']!r} ({LOCALE})", lambda: None)
        return
    locales = {
        loc["attributes"]["locale"]
        for loc in asc.get(f"/{owner['type']}/{owner['id']}/localizations")
    }
    if LOCALE in locales:
        return
    plan(
        f"localize {owner['attributes']['vendorIdentifier']} as {attrs['name']!r} ({LOCALE})",
        lambda: asc.create(
            kind,
            {**attrs, "locale": LOCALE},
            {relationship: (owner["type"], owner["id"])},
        ),
    )


if __name__ == "__main__":
    raise SystemExit(main())
