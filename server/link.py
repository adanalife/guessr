"""POST /api/link -- fold one browser's plays into another's, so a player on a
phone and a desktop places once instead of twice.

No account: the player id already is the credential. It is minted in the
browser and never appears in a response, so holding both ids is proof of
holding both browsers. The flip side is that anyone who learns an id can take
that history -- the same exposure the id already carries, since it can post
plays too.
"""

import re
import secrets

from server import rules

# UPDATE OR IGNORE keeps the row already under `to` when both browsers answered
# the same round on the same date (first write wins), and SWEEP clears the
# mover's leftovers, or the merge silently is not one.
MOVE = "UPDATE OR IGNORE plays SET player_id = ? WHERE player_id = ?"
SWEEP = "DELETE FROM plays WHERE player_id = ?"


async def link(db, body) -> tuple[int, dict]:
    source = body.get("from") if isinstance(body, dict) else None
    target = body.get("to") if isinstance(body, dict) else None
    if not rules.is_player_id(source) or not rules.is_player_id(target):
        return 400, {"error": "expected {from, to}"}
    # Opening your own link asks for nothing, and SWEEP would delete every row
    # MOVE just moved onto itself.
    if source == target:
        return 200, {"moved": 0}
    # One transaction: SWEEP assumes MOVE ran.
    moved, _ = await db.batch([(MOVE, target, source), (SWEEP, source)])
    return 200, {"moved": moved}


# Link codes: the device with the history asks for one, a person types it into
# the new device, and the claim runs the merge above with the new device as the
# mover. functions/api/link/code.js and claim.js carry the reasoning; the SQL is
# the same text, so the two runtimes share a clock (SQLite's) and a format.
#
# ponytail: no rate limit. 2^40 codes, live ten minutes each: 1,000 guesses a
# second against one live code is ~35 years per hit. Upgrade: a Cloudflare
# rate-limiting rule on /api/link/claim, then a longer code or shorter TTL.
ALPHABET = "ABCDEFGHJKLMNPQRSTUVWXYZ23456789"  # no 0/O, 1/I; 32, so & 31 is uniform
LENGTH = 8
NOW = "strftime('%Y-%m-%dT%H:%M:%SZ', 'now')"
SWEEP_CODES = f"DELETE FROM link_codes WHERE player_id = ? OR expires_at <= {NOW}"
ISSUE = """INSERT INTO link_codes (code, player_id, expires_at)
  VALUES (?, ?, strftime('%Y-%m-%dT%H:%M:%SZ', 'now', '+10 minutes'))
  RETURNING expires_at"""
TAKE = f"""DELETE FROM link_codes WHERE code = ? AND expires_at > {NOW}
  RETURNING player_id"""
SWEEP_EXPIRED = f"DELETE FROM link_codes WHERE expires_at <= {NOW}"
SHAPE = re.compile(f"[{ALPHABET}]{{{LENGTH}}}")


def new_code() -> str:
    return "".join(ALPHABET[b & 31] for b in secrets.token_bytes(LENGTH))


def normalize(code) -> str:
    """Forgives case and the spaces or dashes a person types to keep their place."""
    return re.sub(r"[\s-]", "", code).upper() if isinstance(code, str) else ""


async def issue_code(db, body) -> tuple[int, dict]:
    player = body.get("player_id") if isinstance(body, dict) else None
    if not rules.is_player_id(player):
        return 400, {"error": "expected {player_id}"}
    # One live code per player, and expired ones swept, in one statement.
    await db.execute(SWEEP_CODES, player)
    code = new_code()
    row = await db.fetchone(ISSUE, code, player)
    return 200, {"code": code, "expires_at": row["expires_at"]}


async def claim(db, body) -> tuple[int, dict]:
    code = normalize(body.get("code") if isinstance(body, dict) else None)
    source = body.get("from") if isinstance(body, dict) else None
    if not SHAPE.fullmatch(code) or not rules.is_player_id(source):
        return 400, {"error": "expected {code, from}"}
    await db.execute(SWEEP_EXPIRED)
    # Delete-and-read in one statement is what makes a code single-use.
    row = await db.fetchone(TAKE, code)
    # Unknown, expired and used are one answer, so a guesser learns nothing.
    if row is None:
        return 404, {"error": "unknown or expired code"}
    target = row["player_id"]
    if source == target:
        return 200, {"player_id": target, "moved": 0}
    moved, _ = await db.batch([(MOVE, target, source), (SWEEP, source)])
    return 200, {"player_id": target, "moved": moved}
