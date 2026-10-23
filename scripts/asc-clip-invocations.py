#!/usr/bin/env -S uv run --script --quiet
# /// script
# requires-python = ">=3.13"
# dependencies = ["pyjwt", "cryptography"]
# ///
"""TestFlight's App Clip invocations, from `clip_invocations` in the `[beta]`
table of app/store.toml, onto the newest `v*` tag's build.

    uv run scripts/asc-clip-invocations.py          # register what is missing
    uv run scripts/asc-clip-invocations.py --plan   # only say what that would be

An invocation is the entry TestFlight lists under the build to launch its App
Clip from, a URL with a title. They belong to the build's App Clip bundle, so
every build starts with none; `ios:release` runs this after the build is
processed. Idempotent: a URL the build already has is left alone.

Reads ASC_KEY_PATH, ASC_KEY_ID and ASC_ISSUER_ID, as `task ios:release` does.
"""

import importlib.util
from pathlib import Path
import subprocess
import sys

ROOT = Path(__file__).resolve().parent.parent
# asc-beta.py's client and settings, so the two read the key and the file alike.
_spec = importlib.util.spec_from_file_location(
    "asc_beta", ROOT / "scripts" / "asc-beta.py"
)
beta = importlib.util.module_from_spec(_spec)
_spec.loader.exec_module(beta)


def main() -> int:
    if sys.argv[1:] not in ([], ["--plan"]):
        sys.exit(__doc__)
    apply = sys.argv[1:] == []
    want = beta.settings()["beta"].get("clip_invocations", {})
    tag = subprocess.run(
        ["git", "describe", "--tags", "--abbrev=0", "--match", "v*"],
        capture_output=True,
        text=True,
        check=True,
        cwd=ROOT,
    ).stdout.strip()
    res = beta.call(
        "GET",
        f"/builds?filter[app]={beta.app_id()}&filter[preReleaseVersion.version]={tag.lstrip('v')}"
        "&filter[processingState]=VALID&sort=-uploadedDate&limit=1&include=buildBundles",
    )
    if not res["data"]:
        sys.exit(f"{tag} has no VALID build; run: task ios:release")
    label = f"{tag} ({res['data'][0]['attributes']['version']})"
    clip = next(
        (
            b
            for b in res.get("included", [])
            if b["type"] == "buildBundles"
            and b["attributes"]["bundleType"] == "APP_CLIP"
        ),
        None,
    )
    if clip is None:
        print(f"{label} carries no App Clip; nothing to register")
        return 0
    have = {
        inv["attributes"]["url"]
        for inv in beta.get(f"/buildBundles/{clip['id']}/betaAppClipInvocations")
    }
    missing = {title: url for title, url in want.items() if url not in have}
    for title, url in missing.items():
        print(f"{'adding' if apply else 'would add'}: {title!r} -> {url} on {label}")
        if apply:
            beta.call(
                "POST",
                "/betaAppClipInvocations",
                {
                    "data": {
                        "type": "betaAppClipInvocations",
                        "attributes": {"url": url},
                        "relationships": {
                            "buildBundle": {
                                "data": {"type": "buildBundles", "id": clip["id"]}
                            },
                            "betaAppClipInvocationLocalizations": {
                                "data": [
                                    {
                                        "type": "betaAppClipInvocationLocalizations",
                                        "id": "${localization}",
                                    }
                                ]
                            },
                        },
                    },
                    # An inline create: the local id above names this entry.
                    "included": [
                        {
                            "type": "betaAppClipInvocationLocalizations",
                            "id": "${localization}",
                            "attributes": {"locale": beta.LOCALE, "title": title},
                        }
                    ],
                },
            )
    if not missing:
        print(f"{label} has every App Clip invocation in app/store.toml")
    return 0


if __name__ == "__main__":
    sys.exit(main())
