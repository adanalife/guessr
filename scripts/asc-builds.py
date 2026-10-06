#!/usr/bin/env -S uv run --script
# /// script
# requires-python = ">=3.11"
# dependencies = ["pyjwt", "cryptography"]
# ///
"""What App Store Connect holds for the iOS app, and whether it matches the tags.

Lists the newest builds with the marketing version each carries, and exits
non-zero unless the newest `v*` tag has a VALID (installable) build. `--wait`
polls once a minute until it does or the budget (default 20 minutes) runs out,
since Apple takes 5-15 minutes to process an upload.

Reads ASC_KEY_PATH, ASC_KEY_ID and ASC_ISSUER_ID from the environment.
"""

import argparse
import json
import os
import subprocess
import sys
import time
import urllib.error
import urllib.parse
import urllib.request

import jwt

API = "https://api.appstoreconnect.apple.com/v1"
BUNDLE_ID = "lol.dana.guessr"


def token() -> str:
    """A ten-minute ES256 assertion, which is the only auth the API takes."""
    try:
        key_path = os.environ["ASC_KEY_PATH"]
        key_id = os.environ["ASC_KEY_ID"]
        issuer = os.environ["ASC_ISSUER_ID"]
    except KeyError as missing:
        sys.exit(f"{missing.args[0]} is not set — see app/README.md")
    with open(os.path.expanduser(key_path)) as f:
        key = f.read()
    now = int(time.time())
    return jwt.encode(
        {"iss": issuer, "iat": now, "exp": now + 600, "aud": "appstoreconnect-v1"},
        key,
        algorithm="ES256",
        headers={"kid": key_id, "typ": "JWT"},
    )


def get(path: str, **query: str) -> dict:
    """One GET, with a fresh token so a long poll can't outlive it."""
    url = f"{API}/{path}?{urllib.parse.urlencode(query)}"
    req = urllib.request.Request(url, headers={"Authorization": f"Bearer {token()}"})
    try:
        with urllib.request.urlopen(req) as response:
            return json.load(response)
    except urllib.error.HTTPError as e:
        # The API says why in a body the default message throws away.
        sys.exit(f"App Store Connect returned {e.code} for /{path}: {e.read()[:400]}")


def newest_tag() -> str | None:
    tags = subprocess.run(
        ["git", "tag", "--list", "v*", "--sort=-v:refname"],
        capture_output=True,
        text=True,
        check=True,
    ).stdout.split()
    return tags[0] if tags else None


def builds() -> list[dict]:
    apps = get("apps", **{"filter[bundleId]": BUNDLE_ID})["data"]
    if not apps:
        sys.exit(
            f"no app record for {BUNDLE_ID} — create one at appstoreconnect.apple.com"
        )
    # A build's `version` is the build number; the marketing version lives on
    # its preReleaseVersion. Sorted by upload time because build numbers sort
    # as strings, and no sparse fields because they drop the `included` block.
    payload = get(
        "builds",
        **{
            "filter[app]": apps[0]["id"],
            "limit": "10",
            "sort": "-uploadedDate",
            "include": "preReleaseVersion,buildBetaDetail",
        },
    )
    side = {
        (i["type"], i["id"]): i.get("attributes", {})
        for i in payload.get("included", [])
    }

    def related(build: dict, name: str, kind: str, field: str) -> str:
        ref = build.get("relationships", {}).get(name, {}).get("data")
        return (side.get((kind, ref["id"]), {}).get(field) if ref else None) or "?"

    return [
        {
            "marketing": related(
                b, "preReleaseVersion", "preReleaseVersions", "version"
            ),
            "build": b["attributes"].get("version") or "?",
            "state": b["attributes"].get("processingState") or "?",
            "beta": related(
                b, "buildBetaDetail", "buildBetaDetails", "internalBuildState"
            ),
            "expires": (b["attributes"].get("expirationDate") or "")[:10],
        }
        for b in payload["data"]
    ]


def show(found: list[dict]) -> None:
    width = max((len(b["marketing"]) for b in found), default=7)
    for b in found:
        print(
            f"{b['marketing']:<{width}}  ({b['build']:>4})  "
            f"{b['state']:<10} {b['beta']:<18} expires {b['expires'] or '—'}"
        )
    if not found:
        print("no builds in App Store Connect")


def verdict(found: list[dict], tag: str) -> tuple[bool, str]:
    want = tag.lstrip("v")
    ours = [b for b in found if b["marketing"] == want]
    valid = next((b for b in ours if b["state"] == "VALID"), None)
    if valid:
        return True, f"✓ {tag} → build {valid['build']} is VALID ({valid['beta']})"
    if ours:
        return (
            False,
            f"✗ {tag} has a build ({ours[0]['build']}) but it is {ours[0]['state']}",
        )
    return False, f"✗ {tag} has no build in App Store Connect — run: task ios:release"


def main() -> int:
    parser = argparse.ArgumentParser(description=__doc__.split("\n")[0])
    parser.add_argument(
        "--wait",
        nargs="?",
        const=20,
        type=int,
        metavar="MINUTES",
        help="poll until the newest tag has a VALID build (default budget 20 min)",
    )
    args = parser.parse_args()

    tag = newest_tag()
    deadline = time.monotonic() + 60 * (args.wait or 0)
    while True:
        found = builds()
        if tag is None:
            show(found)
            print("\nno v* tag in this checkout — nothing to compare against")
            return 0
        ok, line = verdict(found, tag)
        if ok or args.wait is None or time.monotonic() >= deadline:
            show(found)
            print("\n" + line)
            return 0 if ok else 1
        left = int((deadline - time.monotonic()) / 60)
        print(f"{line} — polling again in a minute ({left} min left)", flush=True)
        time.sleep(60)


if __name__ == "__main__":
    raise SystemExit(main())
