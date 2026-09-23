"""POST /api/link -- fold one browser's plays into another's, so a player on a
phone and a desktop places once instead of twice.

No account: the player id already is the credential. It is minted in the
browser and never appears in a response, so holding both ids is proof of
holding both browsers. The flip side is that anyone who learns an id can take
that history -- the same exposure the id already carries, since it can post
plays too.
"""

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
