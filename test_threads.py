#!/usr/bin/env python3
"""Check the encoder thread count is settable from outside. `python3 test_threads.py`

THREADS has to be settable per machine because the right value is a property of
where the encode runs, not of the code: on the laptop it is half the cores so
the machine stays usable, and in a pod under a CFS quota it has to equal the
pod's CPU limit or the quota is spent scheduling throttled threads (the
2026-06-15 contention incident, written up in video-pipeline's cdk8s). The
constant is evaluated at import, so each case re-imports in a subprocess.
"""

import os
import subprocess
import sys

DEFAULT = max(1, (os.cpu_count() or 2) // 2)


def threads_with(value):
    env = os.environ.copy()
    env.pop("THREADS", None)
    if value is not None:
        env["THREADS"] = value
    out = subprocess.run(
        [sys.executable, "-c", "import make_rounds; print(make_rounds.THREADS)"],
        capture_output=True,
        text=True,
        env=env,
        check=True,
        cwd=os.path.dirname(os.path.abspath(__file__)),
    )
    return int(out.stdout.strip())


# Set, the variable is the count -- the pod's CPU limit travels through here.
assert threads_with("3") == 3

# Unset, the laptop default: half the cores, floor 1.
assert threads_with(None) == DEFAULT

# Zero falls back to the default rather than asking x264 for zero threads,
# which it would read as "auto" -- the ~1.5x-cores flood the limit exists to stop.
assert threads_with("0") == DEFAULT

print("ok: THREADS follows the environment, and defaults to half the cores")
