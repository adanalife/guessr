"""POST /api/link -- fold one browser's plays into another's, so a player on a
phone and a desktop places once instead of twice.

No account: the player id already is the credential. It is minted in the
browser and appears in no response but a link-code claim (below), so holding
both ids is proof of
holding both browsers. The flip side is that anyone who learns an id can take
that history -- the same exposure the id already carries, since it can post
plays too.
"""

import re
import secrets

from server import rules
from server.leaderboard import PLACEHOLDER, name_expr

# UPDATE OR IGNORE keeps the row already under `to` when both browsers answered
# the same round on the same date (first write wins), and SWEEP clears the
# mover's leftovers, or the merge silently is not one.
MOVE = "UPDATE OR IGNORE plays SET player_id = ? WHERE player_id = ?"
SWEEP = "DELETE FROM plays WHERE player_id = ?"
# The owner's marks travel with the plays: an alias or a star is how a friend
# stays recognizable, and a new device must not shed it. Where both ids carry
# marks the merged player keeps the target's and takes the mover's where the
# target has none, so nothing the owner set is lost to a link.
MOVE_MARKS = """INSERT INTO players (player_id, alias, note, private_name, starred)
  SELECT ?1, alias, note, private_name, starred FROM players WHERE player_id = ?2
  ON CONFLICT (player_id) DO UPDATE SET
    alias = COALESCE(players.alias, excluded.alias),
    note = COALESCE(players.note, excluded.note),
    private_name = COALESCE(players.private_name, excluded.private_name),
    starred = MAX(players.starred, excluded.starred),
    updated_at = datetime('now')"""
SWEEP_MARKS = "DELETE FROM players WHERE player_id = ?"


def merge(target: str, source: str) -> list[tuple]:
    """The one transaction that folds `source` into `target`: SWEEP assumes MOVE
    ran, and SWEEP_MARKS assumes MOVE_MARKS did."""
    return [
        (MOVE, target, source),
        (SWEEP, source),
        (MOVE_MARKS, target, source),
        (SWEEP_MARKS, source),
    ]


async def link(db, body) -> tuple[int, dict]:
    source = body.get("from") if isinstance(body, dict) else None
    target = body.get("to") if isinstance(body, dict) else None
    if not rules.is_player_id(source) or not rules.is_player_id(target):
        return 400, {"error": "expected {from, to}"}
    # Opening your own link asks for nothing, and SWEEP would delete every row
    # MOVE just moved onto itself.
    if source == target:
        return 200, {"moved": 0}
    moved, *_ = await db.batch(merge(target, source))
    return 200, {"moved": moved}


# Link codes: the device with the history asks for one, a person types it into
# the new device, and the claim runs the merge above with the new device as the
# mover.
#
# /api/link needs both ids in one hand, which a URL fragment can only deliver to
# something that opens links: a browser, or the iOS app by way of a universal
# link (web/.well-known/apple-app-site-association). A code goes the other way
# round -- this device asks, a person carries eight letters to the other screen,
# and the server is the only party that ever holds both ids. Anyone can ask for
# a code against any id, which gives them nothing: a code only ever makes its
# *claimer* play as the id behind it, and asking already requires knowing that
# id -- the same secret /api/link and /api/score treat as the whole credential.
#
# No 0/O or 1/I in the alphabet, since the point is being read off one screen
# and typed into another. Expiry is SQLite's clock in the stored format, so it is
# a plain string comparison and no handler reads a clock of its own; expired
# codes are swept by the next issue or claim rather than a schedule, and the
# same sweep drops the asker's earlier codes, so a player has at most one live
# code and asking again replaces it.
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
PEEK = f"SELECT player_id FROM link_codes WHERE code = ? AND expires_at > {NOW}"
# Who a player is on the boards, all time, and how much of a habit it is: the
# dates played and the latest one, which is what tells two aliases apart when
# the points are close. `date` is stored YYYY-MM-DD, so MAX is the latest and
# comes back in the stored form. `?1` twice over, so one argument.
STANDING = f"""SELECT COALESCE(SUM(p.points), 0) AS points, {name_expr("?1")} AS name,
  COUNT(DISTINCT p.date) AS days, MAX(p.date) AS last
  FROM plays p WHERE p.player_id = ?1"""
# The mover's plays a merge into `?1` would lose: the rows MOVE's UPDATE OR
# IGNORE skips because the target already holds that (date, image) under the
# primary key, which SWEEP then deletes.
OVERLAP = """SELECT COUNT(*) AS n FROM plays f
  WHERE f.player_id = ?2 AND EXISTS (SELECT 1 FROM plays t
    WHERE t.player_id = ?1 AND t.date = f.date AND t.image = f.image)"""
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
    moved, *_ = await db.batch(merge(target, source))
    return 200, {"player_id": target, "moved": moved}


async def standing(db, player) -> dict:
    row = await db.fetchone(STANDING, player)
    return {
        "name": row["name"] or PLACEHOLDER,
        "points": row["points"],
        "days": row["days"],
        "last": row["last"],
    }


async def preview(db, body) -> tuple[int, dict]:
    """What a merge would do, so the device can ask before it does: the player
    it would become and the player it would replace, each with their all-time
    standing, and how many of the mover's plays the merge would drop.

    Named by a link code ({code, from}, the typed-code flow) or by both ids
    ({to, from}, a universal link, which carries both and no code). Reads only
    -- a code stays live for the claim."""
    body = body if isinstance(body, dict) else {}
    source = body.get("from")
    if "to" in body and "code" not in body:
        target = body.get("to")
        if not rules.is_player_id(target) or not rules.is_player_id(source):
            return 400, {"error": "expected {code, from} or {to, from}"}
    else:
        code = normalize(body.get("code"))
        if not SHAPE.fullmatch(code) or not rules.is_player_id(source):
            return 400, {"error": "expected {code, from}"}
        row = await db.fetchone(PEEK, code)
        if row is None:
            return 404, {"error": "unknown or expired code"}
        target = row["player_id"]
    # Same id: nothing would move, and OVERLAP would count every row against
    # itself.
    overlap = (
        0 if source == target else (await db.fetchone(OVERLAP, target, source))["n"]
    )
    return 200, {
        "to": await standing(db, target),
        "from": await standing(db, source),
        "overlap": overlap,
    }
