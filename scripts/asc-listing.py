#!/usr/bin/env -S uv run --script --quiet
# /// script
# requires-python = ">=3.13"
# dependencies = ["pyjwt", "cryptography"]
# ///
"""The App Store listing, from app/store.toml into App Store Connect: the app's
name, subtitle, privacy policy and category, the version's text, release type,
build, review details, age rating and screenshots.

    uv run scripts/asc-listing.py           # the plan: what differs
    uv run scripts/asc-listing.py --apply   # write it

Idempotent: everything is read back first and only differences are written, so
a run after a hand edit in the dashboard only brings it back to the file.
app/store.local.toml (gitignored) is merged over app/store.toml for the review
contact and the demo account. The version named in the file is created when
missing, in the state App Store Connect calls Prepare for Submission; the
build is the newest valid TestFlight build of that version, attached only when
it exists. Screenshots upload from the directory the file names, one set per
display type, only where the set is empty. Submitting for review is a click in
App Store Connect, not this script.

Reads ASC_KEY_PATH, ASC_KEY_ID and ASC_ISSUER_ID, as `task ios:release` does.
"""

import hashlib
import json
import os
from pathlib import Path
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
# States a version or app info can still be edited in; the rest are history.
EDITABLE = {
    "PREPARE_FOR_SUBMISSION",
    "DEVELOPER_REJECTED",
    "REJECTED",
    "METADATA_REJECTED",
    "INVALID_BINARY",
    "WAITING_FOR_REVIEW",
    "IN_REVIEW",
    "PENDING_DEVELOPER_RELEASE",
}
# The field names App Store Connect uses, by the file's.
APP_FIELDS = {
    "name": "name",
    "subtitle": "subtitle",
    "privacy_policy_url": "privacyPolicyUrl",
}
VERSION_FIELDS = {
    "description": "description",
    "keywords": "keywords",
    "support_url": "supportUrl",
    "marketing_url": "marketingUrl",
    "promotional_text": "promotionalText",
    "whats_new": "whatsNew",
}
REVIEW_FIELDS = {
    "contact_first_name": "contactFirstName",
    "contact_last_name": "contactLastName",
    "contact_phone": "contactPhone",
    "contact_email": "contactEmail",
    "demo_account_name": "demoAccountName",
    "demo_account_password": "demoAccountPassword",
    "demo_account_required": "demoAccountRequired",
    "notes": "notes",
}
SECRET = {"demoAccountPassword", "contactPhone", "contactEmail"}


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

    def one(self, path: str) -> dict | None:
        """A to-one relationship: the resource, or None where there is none."""
        return self.call("GET", path).get("data")

    def patch(
        self,
        kind: str,
        id_: str,
        attributes: dict | None = None,
        relationships: dict | None = None,
    ) -> dict:
        data: dict = {"type": kind, "id": id_}
        if attributes:
            data["attributes"] = attributes
        if relationships:
            data["relationships"] = {
                name: {"data": {"type": type_, "id": rid}}
                for name, (type_, rid) in relationships.items()
            }
        return self.call("PATCH", f"/{kind}/{id_}", {"data": data})

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

    def upload(self, operations: list[dict], data: bytes) -> None:
        """Apple's asset flow: the reservation named where each chunk goes."""
        for op in operations:
            chunk = data[op["offset"] : op["offset"] + op["length"]]
            req = urllib.request.Request(op["url"], data=chunk, method=op["method"])
            for header in op["requestHeaders"]:
                req.add_header(header["name"], header["value"])
            with urllib.request.urlopen(req) as res:
                res.read()


def settings() -> dict:
    """app/store.toml with app/store.local.toml merged over it, table by table."""
    conf = tomllib.loads((ROOT / "app" / "store.toml").read_text())
    local = ROOT / "app" / "store.local.toml"
    if local.exists():
        for table, values in tomllib.loads(local.read_text()).items():
            if isinstance(values, dict):
                conf.setdefault(table, {}).update(values)
            else:
                conf[table] = values
    return conf


def wanted(fields: dict[str, str], table: dict) -> dict:
    """The file's values under App Store Connect's names; text trimmed."""
    out = {}
    for ours, theirs in fields.items():
        if ours in table:
            v = table[ours]
            out[theirs] = v.strip() if isinstance(v, str) else v
    return out


def differences(want: dict, have: dict) -> dict:
    return {k: v for k, v in want.items() if (have.get(k) or "") != (v or "")}


def shown(attrs: dict) -> str:
    return ", ".join(
        f"{k}={'***' if k in SECRET else json.dumps(v)[:60]}" for k, v in attrs.items()
    )


def editable(resources: list[dict]) -> dict | None:
    for r in resources:
        a = r["attributes"]
        if (
            a.get("appVersionState") or a.get("state") or a.get("appStoreState")
        ) in EDITABLE:
            return r
    return None


def main() -> int:
    apply = sys.argv[1:] == ["--apply"]
    if sys.argv[1:] not in ([], ["--apply"]):
        sys.exit(__doc__)
    conf = settings()
    asc = Client()
    apps = asc.get(f"/apps?filter[bundleId]={BUNDLE_ID}")
    if not apps:
        sys.exit(f"no app with bundle id {BUNDLE_ID}")
    app_id = apps[0]["id"]
    changes = 0

    def plan(what: str, do) -> None:
        nonlocal changes
        changes += 1
        print(f"{'doing' if apply else 'would'}: {what}")
        if apply:
            do()

    def localization(
        parent_kind: str, parent_id: str, kind: str, rel: str, fields: dict
    ) -> None:
        """Create or patch the en-US localization of `parent` to the file's text."""
        have = {
            loc["attributes"]["locale"]: loc
            for loc in asc.get(f"/{parent_kind}/{parent_id}/{kind}")
        }
        want = fields
        if LOCALE not in have:
            plan(
                f"create the {LOCALE} {kind[:-1]}: {shown(want)}",
                lambda: asc.create(
                    kind, {"locale": LOCALE, **want}, {rel: (parent_kind, parent_id)}
                ),
            )
            return
        loc = have[LOCALE]
        diff = differences(want, loc["attributes"])
        if diff:
            plan(
                f"set {kind[:-1]} {shown(diff)}",
                lambda: asc.patch(kind, loc["id"], diff),
            )

    # --- the app: name, subtitle, privacy policy, category -------------------
    info = editable(asc.get(f"/apps/{app_id}/appInfos"))
    if info is None:
        sys.exit("no editable app info; every version is live or replaced")
    localization(
        "appInfos",
        info["id"],
        "appInfoLocalizations",
        "appInfo",
        wanted(APP_FIELDS, conf["app"]),
    )

    cats = {
        name: (asc.one(f"/appInfos/{info['id']}/{name}") or {}).get("id")
        for name in (
            "primaryCategory",
            "primarySubcategoryOne",
            "primarySubcategoryTwo",
        )
    }
    want_cats = {
        "primaryCategory": conf["app"].get("primary_category"),
        "primarySubcategoryOne": conf["app"].get("primary_subcategory_one"),
        "primarySubcategoryTwo": conf["app"].get("primary_subcategory_two"),
    }
    cat_diff = {k: v for k, v in want_cats.items() if v and cats.get(k) != v}
    if cat_diff:
        plan(
            f"set category {shown(cat_diff)} (now {shown(cats)})",
            lambda: asc.patch(
                "appInfos",
                info["id"],
                relationships={k: ("appCategories", v) for k, v in cat_diff.items()},
            ),
        )

    # --- age rating -----------------------------------------------------------
    rating = asc.one(f"/appInfos/{info['id']}/ageRatingDeclaration")
    if rating:
        print("age rating now:", shown(rating["attributes"]))
        diff = differences(conf.get("age_rating", {}), rating["attributes"])
        if diff:
            plan(
                f"set age rating {shown(diff)}",
                lambda: asc.patch("ageRatingDeclarations", rating["id"], diff),
            )

    # --- the version ----------------------------------------------------------
    version_string = conf["version"]
    listing = conf["listing"]
    versions = asc.get(f"/apps/{app_id}/appStoreVersions?filter[platform]=IOS")
    version = editable(versions)
    if version is None:
        plan(
            f"create App Store version {version_string}, release {listing['release_type']}",
            lambda: asc.create(
                "appStoreVersions",
                {
                    "platform": "IOS",
                    "versionString": version_string,
                    "releaseType": listing["release_type"],
                },
                {"app": ("apps", app_id)},
            ),
        )
        if not apply:
            print(
                "the version's text, build, review details and screenshots follow once it exists"
            )
            return done(changes, apply)
        version = editable(
            asc.get(f"/apps/{app_id}/appStoreVersions?filter[platform]=IOS")
        )
    vid = version["id"]
    vattrs = version["attributes"]
    state = vattrs.get("appVersionState") or vattrs.get("appStoreState")
    print(
        f"version {vattrs['versionString']} is {state}, release {vattrs.get('releaseType')}"
    )
    vdiff = {}
    if vattrs["versionString"] != version_string:
        vdiff["versionString"] = version_string
    if vattrs.get("releaseType") != listing["release_type"]:
        vdiff["releaseType"] = listing["release_type"]
    if vdiff:
        plan(
            f"set version {shown(vdiff)}",
            lambda: asc.patch("appStoreVersions", vid, vdiff),
        )

    localization(
        "appStoreVersions",
        vid,
        "appStoreVersionLocalizations",
        "appStoreVersion",
        wanted(VERSION_FIELDS, listing),
    )

    # --- the build ------------------------------------------------------------
    attached = asc.one(f"/appStoreVersions/{vid}/build")
    builds = asc.get(
        f"/builds?filter[app]={app_id}&filter[preReleaseVersion.version]={version_string}"
        "&filter[processingState]=VALID&sort=-uploadedDate&limit=1"
    )
    if not builds:
        print(
            f"no valid build of {version_string} in TestFlight yet; run `task ios:release` from the tag"
        )
    elif (attached or {}).get("id") != builds[0]["id"]:
        number = builds[0]["attributes"]["version"]
        plan(
            f"attach build {version_string} ({number})",
            lambda: asc.call(
                "PATCH",
                f"/appStoreVersions/{vid}/relationships/build",
                {"data": {"type": "builds", "id": builds[0]["id"]}},
            ),
        )

    # --- review details -------------------------------------------------------
    review = asc.one(f"/appStoreVersions/{vid}/appStoreReviewDetail")
    want = wanted(REVIEW_FIELDS, conf.get("review", {}))
    missing = [
        k
        for k in ("contactLastName", "contactPhone", "contactEmail")
        if not want.get(k)
    ]
    if want.get("demoAccountRequired") and not (
        want.get("demoAccountName") and want.get("demoAccountPassword")
    ):
        missing += ["demoAccountName", "demoAccountPassword"]
    if missing:
        print(f"review details missing from app/store.local.toml: {', '.join(missing)}")
    if review is None:
        plan(
            f"create review details: {shown(want)}",
            lambda: asc.create(
                "appStoreReviewDetails",
                want,
                {"appStoreVersion": ("appStoreVersions", vid)},
            ),
        )
    else:
        diff = differences(want, review["attributes"])
        if diff:
            plan(
                f"set review details {shown(diff)}",
                lambda: asc.patch("appStoreReviewDetails", review["id"], diff),
            )

    # --- screenshots ----------------------------------------------------------
    locs = {
        loc["attributes"]["locale"]: loc
        for loc in asc.get(f"/appStoreVersions/{vid}/appStoreVersionLocalizations")
    }
    if LOCALE in locs:
        shots = conf.get("screenshots", {})
        base = ROOT / shots.get("dir", "app/.build/screenshots")
        sets = {
            s["attributes"]["screenshotDisplayType"]: s
            for s in asc.get(
                f"/appStoreVersionLocalizations/{locs[LOCALE]['id']}/appScreenshotSets"
            )
        }
        for display, sub in shots.items():
            if display == "dir":
                continue
            files = sorted((base / sub).glob("*.png"))
            have = sets.get(display)
            count = (
                len(asc.get(f"/appScreenshotSets/{have['id']}/appScreenshots"))
                if have
                else 0
            )
            if count:
                print(f"{display}: {count} screenshot(s) in App Store Connect")
                continue
            if not files:
                print(
                    f"{display}: none in App Store Connect and none in {base / sub}; run `task ios:screenshots`"
                )
                continue
            plan(
                f"upload {len(files)} {display} screenshot(s) from {base / sub}",
                lambda display=display, files=files, have=have: screenshots(
                    asc, locs[LOCALE]["id"], display, files, have
                ),
            )
    elif not apply:
        print("screenshots follow once the localization exists")

    return done(changes, apply)


def screenshots(
    asc: Client, loc_id: str, display: str, files: list[Path], have: dict | None
) -> None:
    set_ = have or asc.create(
        "appScreenshotSets",
        {"screenshotDisplayType": display},
        {"appStoreVersionLocalization": ("appStoreVersionLocalizations", loc_id)},
    )
    for f in files:
        data = f.read_bytes()
        shot = asc.create(
            "appScreenshots",
            {"fileName": f.name, "fileSize": len(data)},
            {"appScreenshotSet": ("appScreenshotSets", set_["id"])},
        )
        asc.upload(shot["attributes"]["uploadOperations"], data)
        asc.patch(
            "appScreenshots",
            shot["id"],
            {"uploaded": True, "sourceFileChecksum": hashlib.md5(data).hexdigest()},
        )
        print(f"  uploaded {f.name}")


def done(changes: int, apply: bool) -> int:
    if not changes:
        print("nothing to do: App Store Connect matches app/store.toml")
    elif not apply:
        print(f"{changes} change(s); run again with --apply")
    return 0


if __name__ == "__main__":
    sys.exit(main())
