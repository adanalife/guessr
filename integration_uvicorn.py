#!/usr/bin/env python3
"""contract.py against the Python app under uvicorn, the stack guessr runs on
anywhere that is not Cloudflare.

integration.sh's world, built without wrangler: fixture.py's round set and
contract.py's seed played into a sqlite file migrated from migrations/, and the
same one clip -- the furthest day's opener -- in a directory standing in for
the bucket. server/local.py serves it all, static site included.

Twitch is the one thing stubbed: the fetch seam answers /oauth2/validate for
contract.OWNER_TOKEN as the owner and refuses every other token, and passes
anything else (the YouTube feed) through to the network. So the gate itself is
real; only Twitch's side of it is not.

    uv run --project api python integration_uvicorn.py   # task test:integration:py
"""

import json
import os
import subprocess
import sys
import tempfile
import threading
import time
from pathlib import Path

import uvicorn

import contract
from server import local
from server.admin_auth import VALIDATE_URL, Admins
from server.db import Sqlite

HERE = Path(__file__).resolve().parent
PORT = int(os.environ.get("PORT", "8789"))
BASE = f"http://127.0.0.1:{PORT}"
DAYS = os.environ.get("DAYS", "6")  # see integration.sh: the reject needs six
OWNER, APP = "1", "contract-app"
ADMINS = Admins(owner_id=OWNER, channel_id="2", client_ids=frozenset({APP}))


async def fetch(url, headers=None):
    if url != VALIDATE_URL:
        return await local.fetch(url, headers)
    if (headers or {}).get("Authorization") != f"OAuth {contract.OWNER_TOKEN}":
        return 401, json.dumps({"status": 401, "message": "invalid access token"})
    who = {"client_id": APP, "login": "contract", "user_id": OWNER, "scopes": []}
    return 200, json.dumps(who)


def seeded(state: Path) -> Sqlite:
    subprocess.run(
        [sys.executable, "fixture.py", "--days", DAYS, "--dest", state],
        cwd=HERE,
        check=True,
    )
    db = Sqlite(str(state / "answers.db")).migrate()
    for sql in (state / "answers.sql", state / "rounds.sql"):
        db.conn.executescript(sql.read_text())
    db.conn.executescript(contract.seed_sql())
    return db


def main() -> int:
    with tempfile.TemporaryDirectory() as tmp:
        state = Path(tmp)
        db = seeded(state)
        clip = db.conn.execute(
            "SELECT image FROM round_days ORDER BY date DESC, position LIMIT 1"
        ).fetchone()[0]
        (state / clip).parent.mkdir(parents=True)
        (state / clip).write_bytes(b"stand-in bytes, not a real mp4\n")

        app = local.build(db, state, ADMINS, fetch)
        server = uvicorn.Server(
            uvicorn.Config(app, host="127.0.0.1", port=PORT, log_level="warning")
        )
        verdict = []

        # The contract runs beside the server rather than in front of it: the
        # sqlite connection belongs to the thread that opened it, which is the
        # one uvicorn's loop has to run on.
        def run_contract():
            while not server.started:
                time.sleep(0.1)
            for mode in (["twitch"], []):
                print(f"== contract {' '.join(mode) or 'full'}", flush=True)
                rc = subprocess.run(
                    [sys.executable, "contract.py", BASE, *mode], cwd=HERE
                ).returncode
                verdict.append(rc)
                if rc:
                    break
            server.should_exit = True

        threading.Thread(target=run_contract, daemon=True).start()
        server.run()
    return 0 if verdict and not any(verdict) else 1


if __name__ == "__main__":
    raise SystemExit(main())
