#!/usr/bin/env -S uv run --script --quiet
# /// script
# requires-python = ">=3.13"
# dependencies = ["pyjwt", "cryptography"]
# ///
"""External TestFlight testing, from the `[beta]` table of app/store.toml.

    uv run scripts/asc-beta.py setup           # the plan: what differs
    uv run scripts/asc-beta.py setup --apply   # write it
    uv run scripts/asc-beta.py ship            # the newest tag's build → external testers

`setup` is idempotent, like `asc-listing.py`: the beta description and feedback
email testers see, the contact App Review uses for beta builds (the `[review]`
table's, with app/store.local.toml merged over it), and the external group with
its public link. `ship` adds the newest `v*` tag's VALID build to that group,
points its *What to Test* at the GitHub release, and submits it for Beta App
Review unless it has been already. `ios:release` runs it last.

External testers never join the App Store Connect team: one email from
TestFlight, or the public link, and they install. The internal *Friends &
Family* group stays for the owner, since it gets every build with no review.

Reads ASC_KEY_PATH, ASC_KEY_ID and ASC_ISSUER_ID, as `task ios:release` does.
"""

import json
import os
from pathlib import Path
import subprocess
import sys
import time
import tomllib
import urllib.error
import urllib.request

import jwt

API = "https://api.appstoreconnect.apple.com/v1"
BUNDLE_ID = "lol.dana.guessr"
LOCALE = "en-US"
ROOT = Path(__file__).resolve().parent.parent
RELEASES = "https://github.com/adanalife/guessr/releases/tag"
REVIEW_FIELDS = {
    "contact_first_name": "contactFirstName",
    "contact_last_name": "contactLastName",
    "contact_phone": "contactPhone",
    "contact_email": "contactEmail",
}


def call(method: str, path: str, body: dict | None = None) -> dict:
    """One call, with a fresh ten-minute token so `ship` can't outlive one."""
    now = int(time.time())
    auth = jwt.encode(
        {
            "iss": os.environ["ASC_ISSUER_ID"],
            "iat": now,
            "exp": now + 600,
            "aud": "appstoreconnect-v1",
        },
        open(os.path.expanduser(os.environ["ASC_KEY_PATH"])).read(),
        algorithm="ES256",
        headers={"kid": os.environ["ASC_KEY_ID"]},
    )
    req = urllib.request.Request(
        API + path,
        data=json.dumps(body).encode() if body else None,
        method=method,
        headers={"Authorization": f"Bearer {auth}", "Content-Type": "application/json"},
    )
    try:
        with urllib.request.urlopen(req) as res:
            return json.load(res) if res.status != 204 else {}
    except urllib.error.HTTPError as e:
        sys.exit(f"{method} {path}: {e.code}\n{e.read().decode()[:1500]}")


def get(path: str) -> list[dict] | dict | None:
    return call("GET", path).get("data")


def resource(kind: str, attributes: dict, relationships: dict) -> dict:
    data = {
        "type": kind,
        "relationships": {
            name: {"data": {"type": type_, "id": id_}}
            for name, (type_, id_) in relationships.items()
        },
    }
    # A beta review submission has no attributes, and the API wants none sent.
    if attributes:
        data["attributes"] = attributes
    return {"data": data}


def settings() -> dict:
    """app/store.toml with app/store.local.toml merged over it, table by table."""
    conf = tomllib.loads((ROOT / "app" / "store.toml").read_text())
    local = ROOT / "app" / "store.local.toml"
    if local.exists():
        for table, values in tomllib.loads(local.read_text()).items():
            conf.setdefault(table, {}).update(values)
    return conf


def app_id() -> str:
    apps = get(f"/apps?filter[bundleId]={BUNDLE_ID}")
    if not apps:
        sys.exit(f"no app with bundle id {BUNDLE_ID}")
    return apps[0]["id"]


def external_group(aid: str, name: str) -> dict | None:
    for group in get(f"/apps/{aid}/betaGroups"):
        if (
            group["attributes"]["name"] == name
            and not group["attributes"]["isInternalGroup"]
        ):
            return group
    return None


def setup(apply: bool) -> int:
    conf = settings()
    beta, review = conf["beta"], conf.get("review", {})
    aid = app_id()
    changes = 0

    def plan(what: str, do) -> None:
        nonlocal changes
        changes += 1
        print(f"{'doing' if apply else 'would'}: {what}")
        if apply:
            do()

    # What a tester reads on the TestFlight page, and where their feedback goes.
    want = {
        "description": beta["description"].strip(),
        "feedbackEmail": beta.get("feedback_email") or review.get("contact_email"),
        "marketingUrl": conf["listing"]["marketing_url"],
        "privacyPolicyUrl": conf["app"]["privacy_policy_url"],
    }
    if not want["feedbackEmail"]:
        sys.exit(
            "no feedback email: set [beta] feedback_email or [review] contact_email"
        )
    locs = {
        loc["attributes"]["locale"]: loc
        for loc in get(f"/apps/{aid}/betaAppLocalizations")
    }
    if LOCALE not in locs:
        plan(
            f"create the {LOCALE} beta description",
            lambda: call(
                "POST",
                "/betaAppLocalizations",
                resource(
                    "betaAppLocalizations",
                    {"locale": LOCALE, **want},
                    {"app": ("apps", aid)},
                ),
            ),
        )
    else:
        have = locs[LOCALE]["attributes"]
        diff = {k: v for k, v in want.items() if have.get(k) != v}
        if diff:
            plan(
                f"set beta description fields {', '.join(diff)}",
                lambda: call(
                    "PATCH",
                    f"/betaAppLocalizations/{locs[LOCALE]['id']}",
                    {
                        "data": {
                            "type": "betaAppLocalizations",
                            "id": locs[LOCALE]["id"],
                            "attributes": diff,
                        }
                    },
                ),
            )

    # Who Beta App Review calls. Every app has exactly one of these, empty or not.
    detail = get(f"/apps/{aid}/betaAppReviewDetail")
    want = {
        theirs: review[ours]
        for ours, theirs in REVIEW_FIELDS.items()
        if review.get(ours)
    }
    want |= {"demoAccountRequired": False, "notes": review.get("notes", "").strip()}
    missing = [ours for ours in REVIEW_FIELDS if not review.get(ours)]
    if missing:
        print(
            f"beta review contact missing from app/store.local.toml [review]: {', '.join(missing)}"
        )
    diff = {k: v for k, v in want.items() if detail["attributes"].get(k) != v}
    if diff:
        plan(
            f"set beta review details {', '.join(diff)}",
            lambda: call(
                "PATCH",
                f"/betaAppReviewDetails/{detail['id']}",
                {
                    "data": {
                        "type": "betaAppReviewDetails",
                        "id": detail["id"],
                        "attributes": diff,
                    }
                },
            ),
        )

    # The external group, and the public link anyone holding it can join by.
    want = {
        "publicLinkEnabled": True,
        "publicLinkLimitEnabled": True,
        "publicLinkLimit": beta["public_link_limit"],
        "feedbackEnabled": True,
    }
    group = external_group(aid, beta["group"])
    if group is None:
        plan(
            f"create the external group {beta['group']!r} with a public link for {beta['public_link_limit']}",
            lambda: call(
                "POST",
                "/betaGroups",
                resource(
                    "betaGroups",
                    {"name": beta["group"], **want},
                    {"app": ("apps", aid)},
                ),
            ),
        )
    else:
        diff = {k: v for k, v in want.items() if group["attributes"].get(k) != v}
        if diff:
            plan(
                f"set group {beta['group']!r} {', '.join(f'{k}={v}' for k, v in diff.items())}",
                lambda: call(
                    "PATCH",
                    f"/betaGroups/{group['id']}",
                    {
                        "data": {
                            "type": "betaGroups",
                            "id": group["id"],
                            "attributes": diff,
                        }
                    },
                ),
            )
        link = group["attributes"].get("publicLink")
        print(
            f"public link: {link or 'none until the group has a build through beta review'}"
        )

    if not changes:
        print("nothing to do: App Store Connect matches app/store.toml [beta]")
    elif not apply:
        print(f"{changes} change(s); run again with --apply")
    return 0


def ship() -> int:
    beta = settings()["beta"]
    tag = subprocess.run(
        ["git", "describe", "--tags", "--abbrev=0", "--match", "v*"],
        capture_output=True,
        text=True,
        check=True,
        cwd=ROOT,
    ).stdout.strip()
    aid = app_id()
    group = external_group(aid, beta["group"])
    if group is None:
        sys.exit(
            f"no external group {beta['group']!r}; run: task ios:beta:setup -- --apply"
        )
    builds = get(
        f"/builds?filter[app]={aid}&filter[preReleaseVersion.version]={tag.lstrip('v')}"
        "&filter[processingState]=VALID&sort=-uploadedDate&limit=1"
    )
    if not builds:
        sys.exit(f"{tag} has no VALID build; run: task ios:release")
    build = builds[0]
    label = f"{tag} ({build['attributes']['version']})"

    in_group = {b["id"] for b in get(f"/betaGroups/{group['id']}/builds?limit=200")}
    if build["id"] not in in_group:
        call(
            "POST",
            f"/betaGroups/{group['id']}/relationships/builds",
            {"data": [{"type": "builds", "id": build["id"]}]},
        )
        print(f"added {label} to {beta['group']!r}")

    # What to Test: TestFlight shows it above the install button.
    notes = f"What changed in {tag}: {RELEASES}/{tag}"
    locs = get(f"/builds/{build['id']}/betaBuildLocalizations")
    if not any(loc["attributes"]["locale"] == LOCALE for loc in locs):
        call(
            "POST",
            "/betaBuildLocalizations",
            resource(
                "betaBuildLocalizations",
                {"locale": LOCALE, "whatsNew": notes},
                {"build": ("builds", build["id"])},
            ),
        )

    state = get(f"/builds/{build['id']}/buildBetaDetail")["attributes"][
        "externalBuildState"
    ]
    if state == "READY_FOR_BETA_SUBMISSION":
        call(
            "POST",
            "/betaAppReviewSubmissions",
            resource(
                "betaAppReviewSubmissions", {}, {"build": ("builds", build["id"])}
            ),
        )
        print(f"submitted {label} for Beta App Review; testers get it once it passes")
    else:
        print(f"{label} is {state}; nothing to submit")
    return 0


if __name__ == "__main__":
    match sys.argv[1:]:
        case ["setup"]:
            sys.exit(setup(apply=False))
        case ["setup", "--apply"]:
            sys.exit(setup(apply=True))
        case ["ship"]:
            sys.exit(ship())
        case _:
            sys.exit(__doc__)
