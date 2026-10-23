#!/usr/bin/env -S uv run --script --quiet
# /// script
# requires-python = ">=3.13"
# dependencies = ["pyjwt", "cryptography"]
# ///
"""The App Store listing, from app/store.toml into App Store Connect: the app's
name, subtitle, privacy policy and category, the version's text, release type,
build, review details, age rating, screenshots and the App Clip's default
experience.

    uv run scripts/asc-listing.py           # the plan: what differs
    uv run scripts/asc-listing.py --apply   # write it

Idempotent: everything is read back first and only differences are written, so
a run after a hand edit in the dashboard only brings it back to the file.
app/store.local.toml (gitignored) is merged over app/store.toml for the review
contact and the demo account. The version named in the file is created when
missing, in the state App Store Connect calls Prepare for Submission; the
build is the newest valid TestFlight build of that version, attached only when
it exists. Screenshots upload from the directory the file names, one set per
display type, only where the set is empty. The App Clip's default experience
(the card iOS shows before the clip opens) is created on the version with the
file's action and subtitle, and its header image uploads from the file
`task appclip:image` renders wherever App Store Connect holds a different one.
Submitting for review is a click in App Store Connect, not this script.

Reads ASC_KEY_PATH, ASC_KEY_ID and ASC_ISSUER_ID, as `task ios:release` does.
"""

import hashlib
import json
import os
from pathlib import Path
import struct
import sys
import time
import tomllib
import urllib.error
import urllib.request

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
# The App Clip card: its button, the subtitle's limit, the header image's size.
CLIP_ACTIONS = {"OPEN", "VIEW", "PLAY"}
CLIP_SUBTITLE_MAX = 56
HEADER_SIZE = (1800, 1200)


def token() -> str:
    import jwt  # here, so the tests import this file without the script's deps

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
    """What `want` sets that `have` doesn't. Unset (None) reads as an empty
    string, so a blank field counts as set; False stays False, so a no answer
    differs from a question App Store Connect has never had answered."""

    def norm(v):
        return "" if v is None else v

    return {k: v for k, v in want.items() if norm(have.get(k)) != norm(v)}


def shown(attrs: dict) -> str:
    return ", ".join(
        f"{k}={'***' if k in SECRET else json.dumps(v)[:60]}" for k, v in attrs.items()
    )


def in_full(attrs: dict) -> None:
    """The release notes as the store page will show them, since `shown`
    cuts every value to one short line and these are read before they ship."""
    if attrs.get("whatsNew"):
        print("  What's New, as it will read:")
        for line in attrs["whatsNew"].splitlines():
            print(f"    {line}")


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
            in_full(want)
            return
        loc = have[LOCALE]
        diff = differences(want, loc["attributes"])
        if diff:
            plan(
                f"set {kind[:-1]} {shown(diff)}",
                lambda: asc.patch(kind, loc["id"], diff),
            )
            in_full(diff)

    # --- the app: name, subtitle, privacy policy, category -------------------
    # Once a version is live its app info is read-only, and App Store Connect
    # opens an editable one only alongside the next version. The run that
    # creates that version leaves the app info to the run after it.
    info = editable(asc.get(f"/apps/{app_id}/appInfos"))
    if info is None:
        print(
            "app info is read-only until the next version exists; run again after it is created"
        )
    else:
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
                "secondaryCategory",
            )
        }
        want_cats = {
            "primaryCategory": conf["app"].get("primary_category"),
            "primarySubcategoryOne": conf["app"].get("primary_subcategory_one"),
            "primarySubcategoryTwo": conf["app"].get("primary_subcategory_two"),
            "secondaryCategory": conf["app"].get("secondary_category"),
        }
        cat_diff = {k: v for k, v in want_cats.items() if v and cats.get(k) != v}
        if cat_diff:
            plan(
                f"set category {shown(cat_diff)} (now {shown(cats)})",
                lambda: asc.patch(
                    "appInfos",
                    info["id"],
                    relationships={
                        k: ("appCategories", v) for k, v in cat_diff.items()
                    },
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
        if any(v["attributes"]["versionString"] == version_string for v in versions):
            sys.exit(
                f"{version_string} is already on the App Store; set `version` in app/store.toml to the release tag being submitted"
            )
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
                "the version's text, build, review details, screenshots and App Clip experience follow once it exists"
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
    if not listing.get("whats_new", "").strip() and any(
        v["id"] != vid for v in versions
    ):
        print(
            "whats_new is empty in app/store.toml: every version after the first needs release notes before Add for Review"
        )
    vdiff = {}
    if vattrs["versionString"] != version_string:
        vdiff["versionString"] = version_string
    if vattrs.get("releaseType") != listing["release_type"]:
        vdiff["releaseType"] = listing["release_type"]
    if listing.get("copyright") and vattrs.get("copyright") != listing["copyright"]:
        vdiff["copyright"] = listing["copyright"]
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

    # --- the App Clip's default experience ------------------------------------
    # The card iOS shows before the clip opens. It belongs to the version, so
    # every new version starts without one.
    clip = conf.get("app_clip")
    clips = asc.get(f"/apps/{app_id}/appClips") if clip else []
    if clip and not clips:
        print(
            "no App Clip in App Store Connect yet; it appears with the first uploaded build that embeds one"
        )
    elif clip:
        subtitle, action, png = clip_settings(clip)
        experience = experience_for(
            asc.get(
                f"/appClips/{clips[0]['id']}/appClipDefaultExperiences"
                "?include=releaseWithAppStoreVersion"
            ),
            vid,
        )
        if experience is None:
            created: dict = {}
            plan(
                f"create the App Clip default experience, action {action}",
                lambda: created.update(
                    asc.create(
                        "appClipDefaultExperiences",
                        {"action": action},
                        {
                            "appClip": ("appClips", clips[0]["id"]),
                            "releaseWithAppStoreVersion": ("appStoreVersions", vid),
                        },
                    )
                ),
            )
            experience = created or None
        elif experience["attributes"].get("action") != action:
            plan(
                f"set App Clip action {action} (now {experience['attributes'].get('action')})",
                lambda: asc.patch(
                    "appClipDefaultExperiences", experience["id"], {"action": action}
                ),
            )
        if experience is None:
            # Only a plan gets here: what the experience gets once it exists.
            plan(
                f"create the {LOCALE} App Clip subtitle {json.dumps(subtitle)}",
                lambda: None,
            )
            plan(f"upload the App Clip header image from {png}", lambda: None)
        else:
            localization(
                "appClipDefaultExperiences",
                experience["id"],
                "appClipDefaultExperienceLocalizations",
                "appClipDefaultExperience",
                {"subtitle": subtitle},
            )
            clip_locs = {
                loc["attributes"]["locale"]: loc
                for loc in asc.get(
                    f"/appClipDefaultExperiences/{experience['id']}/appClipDefaultExperienceLocalizations"
                )
            }
            if not png.exists():
                print(f"no App Clip header image at {png}; run `task appclip:image`")
            elif LOCALE not in clip_locs:
                plan(f"upload the App Clip header image from {png}", lambda: None)
            else:
                loc_id = clip_locs[LOCALE]["id"]
                data = png.read_bytes()
                if png_size(data) != HEADER_SIZE:
                    sys.exit(f"{png} is {png_size(data)}, not {HEADER_SIZE}")
                have = asc.one(
                    f"/appClipDefaultExperienceLocalizations/{loc_id}/appClipHeaderImage"
                )
                step = header_step(have, hashlib.md5(data).hexdigest())
                if step:
                    plan(
                        f"{step} the App Clip header image from {png}",
                        lambda: header_image(asc, loc_id, png.name, data, have),
                    )

    return done(changes, apply)


def clip_settings(clip: dict) -> tuple[str, str, Path]:
    """The [app_clip] table, checked against what App Store Connect accepts."""
    subtitle = clip["subtitle"].strip()
    if len(subtitle) > CLIP_SUBTITLE_MAX:
        sys.exit(
            f"[app_clip] subtitle is {len(subtitle)} characters; App Store Connect takes {CLIP_SUBTITLE_MAX}"
        )
    if clip["action"] not in CLIP_ACTIONS:
        sys.exit(f"[app_clip] action must be one of {sorted(CLIP_ACTIONS)}")
    return subtitle, clip["action"], ROOT / clip["header_image"]


def experience_for(experiences: list[dict], version_id: str) -> dict | None:
    """The default experience released with the version, of the App Clip's."""
    for e in experiences:
        release = e.get("relationships", {}).get("releaseWithAppStoreVersion", {})
        if (release.get("data") or {}).get("id") == version_id:
            return e
    return None


def png_size(data: bytes) -> tuple[int, int]:
    """Width and height from a PNG's header chunk."""
    return struct.unpack(">II", data[16:24])


def header_step(have: dict | None, checksum: str) -> str | None:
    """What the header image needs: nothing where App Store Connect holds this
    file, uploaded or processing; an upload where it holds none; a replacement
    where it holds another file, or an upload that failed or never finished."""
    if have is None:
        return "upload"
    attrs = have["attributes"]
    state = (attrs.get("assetDeliveryState") or {}).get("state")
    if attrs.get("sourceFileChecksum") == checksum and state in (
        "UPLOAD_COMPLETE",
        "COMPLETE",
    ):
        return None
    return "replace"


def header_image(
    asc: Client, loc_id: str, name: str, data: bytes, have: dict | None
) -> None:
    if have:
        asc.call("DELETE", f"/appClipHeaderImages/{have['id']}")
    image = asc.create(
        "appClipHeaderImages",
        {"fileName": name, "fileSize": len(data)},
        {
            "appClipDefaultExperienceLocalization": (
                "appClipDefaultExperienceLocalizations",
                loc_id,
            )
        },
    )
    asc.upload(image["attributes"]["uploadOperations"], data)
    asc.patch(
        "appClipHeaderImages",
        image["id"],
        {"uploaded": True, "sourceFileChecksum": hashlib.md5(data).hexdigest()},
    )
    print(f"  uploaded {name}")


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
