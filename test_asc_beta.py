#!/usr/bin/env python3
"""Pin scripts/asc-beta.py's plan diff: a field App Store Connect reports as
null where app/store.toml leaves it empty is no change, or `setup` would plan a
PATCH on every run and never read clean."""

import importlib.util
from pathlib import Path

ROOT = Path(__file__).parent
spec = importlib.util.spec_from_file_location(
    "asc_beta", ROOT / "scripts" / "asc-beta.py"
)
beta = importlib.util.module_from_spec(spec)
spec.loader.exec_module(beta)


def test_unset_text_matches_null():
    want = {"notes": "", "demoAccountRequired": False}
    assert beta.changed(want, {"notes": None, "demoAccountRequired": False}) == {}
    assert beta.changed(want, {"notes": "", "demoAccountRequired": False}) == {}


def test_real_differences_still_plan():
    want = {"notes": "hi", "demoAccountRequired": False}
    have = {"notes": None, "demoAccountRequired": None}
    assert beta.changed(want, have) == want
    assert beta.changed({"notes": ""}, {"notes": "old"}) == {"notes": ""}


if __name__ == "__main__":
    for name, fn in sorted(globals().items()):
        if name.startswith("test_"):
            fn()
            print(f"ok {name}")
