#!/usr/bin/env python3
"""Cover server/local.py's directory clip store: the byte ranges it resolves, in
the forms R2 reports them, and that a key cannot climb out of its directory --
which a bucket's flat keys never could. The contract run covers the rest.

    uv run --project api python test_server_local.py
"""

import asyncio
import tempfile
from pathlib import Path

from server.clips import Range
from server.local import Files, resolve_range

assert resolve_range("bytes=0-3", 10) == Range(offset=0, length=4)
assert resolve_range("bytes=4-", 10) == Range(offset=4)
assert resolve_range("bytes=-3", 10) == Range(suffix=3)
assert resolve_range("bytes=8-99", 10) == Range(offset=8, length=2), "clamped"
assert resolve_range("bytes=-99", 10) == Range(suffix=10), "clamped"
for whole in (None, "", "bytes=-", "bytes=10-", "items=0-3", "bytes=0-1,4-5"):
    assert resolve_range(whole, 10) is None, whole


async def main() -> None:
    with tempfile.TemporaryDirectory() as tmp:
        root = Path(tmp) / "bucket"
        (root / "clips").mkdir(parents=True)
        (root / "clips" / "a.mp4").write_bytes(b"0123456789")
        (Path(tmp) / "secret.mp4").write_bytes(b"outside")
        files = Files(root)

        whole = await files.get_clip("clips/a.mp4", {})
        assert whole.body == b"0123456789" and whole.range is None and whole.size == 10
        tail = await files.get_clip("clips/a.mp4", {"range": "bytes=-3"})
        assert tail.body == b"789" and tail.range == Range(suffix=3)
        mid = await files.get_clip("clips/a.mp4", {"range": "bytes=2-4"})
        assert mid.body == b"234"
        same = await files.get_clip("clips/a.mp4", {"if-none-match": whole.etag})
        assert same.body is None and same.etag == whole.etag

        assert await files.get_clip("clips/missing.mp4", {}) is None
        assert await files.get_clip("clips/../../secret.mp4", {}) is None
        assert await files.get_clip("clips", {}) is None, "a directory is no clip"


asyncio.run(main())
print("ok: test_server_local")
