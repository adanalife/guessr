#!/usr/bin/env python3
"""Pin scripts/asc-listing.py's App Clip decisions: which default experience
belongs to the version, when the header image uploads, and what the
[app_clip] table may say. A wrong answer here re-uploads on every run or never
uploads at all, and either reads as a clean plan."""

import importlib.util
from pathlib import Path
import struct

ROOT = Path(__file__).parent
spec = importlib.util.spec_from_file_location(
    "asc_listing", ROOT / "scripts" / "asc-listing.py"
)
listing = importlib.util.module_from_spec(spec)
spec.loader.exec_module(listing)


def experience(id_, version_id):
    data = {"type": "appStoreVersions", "id": version_id} if version_id else None
    return {"id": id_, "relationships": {"releaseWithAppStoreVersion": {"data": data}}}


def image(checksum, state):
    return {
        "id": "img",
        "attributes": {
            "sourceFileChecksum": checksum,
            "assetDeliveryState": {"state": state},
        },
    }


def test_experience_is_the_versions():
    exps = [experience("old", "v1"), experience("draft", None), experience("new", "v2")]
    assert listing.experience_for(exps, "v2")["id"] == "new"
    assert listing.experience_for(exps, "v3") is None
    assert listing.experience_for([], "v2") is None


def test_experience_without_relationship_data():
    assert listing.experience_for([{"id": "x"}], "v1") is None


def test_header_uploads_where_there_is_none():
    assert listing.header_step(None, "abc") == "upload"


def test_header_kept_when_same_file_landed_or_processing():
    assert listing.header_step(image("abc", "COMPLETE"), "abc") is None
    assert listing.header_step(image("abc", "UPLOAD_COMPLETE"), "abc") is None


def test_header_replaced_when_different_failed_or_unfinished():
    assert listing.header_step(image("old", "COMPLETE"), "abc") == "replace"
    assert listing.header_step(image("abc", "FAILED"), "abc") == "replace"
    assert listing.header_step(image("abc", "AWAITING_UPLOAD"), "abc") == "replace"
    assert listing.header_step(image(None, None), "abc") == "replace"


def test_png_size_reads_the_header_chunk():
    head = b"\x89PNG\r\n\x1a\n" + struct.pack(">I", 13) + b"IHDR"
    assert listing.png_size(head + struct.pack(">II", 1800, 1200)) == (1800, 1200)


def test_clip_settings_checks_the_table():
    ok = {"subtitle": " Play \n", "action": "PLAY", "header_image": "x.png"}
    assert listing.clip_settings(ok) == ("Play", "PLAY", ROOT / "x.png")
    for bad in ({**ok, "subtitle": "x" * 57}, {**ok, "action": "GO"}):
        try:
            listing.clip_settings(bad)
        except SystemExit:
            continue
        raise AssertionError(f"accepted {bad}")


def test_store_toml_app_clip_passes():
    listing.clip_settings(listing.settings()["app_clip"])


if __name__ == "__main__":
    for name, fn in sorted(globals().items()):
        if name.startswith("test_"):
            fn()
            print(f"ok {name}")
