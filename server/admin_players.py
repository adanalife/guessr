"""The admin surface's player half: everyone who has played, one date's games
player by player, and the private note against a player -- reached by id from
the list, or by board row from a surface that holds no id.

A note is the private half of a `players` row, served by nothing the game
exposes, so every response here is owner-only and never cached. The alias beside
it is published -- it names that player on every board and on the stream
overlay -- so nothing here edits it, and a note write leaves it where it was.
`private_name` and `starred` are the note's kind: the owner's label and a star,
read and written only here.

Each handler takes the resolved `Caller` (None when nobody signed in) and returns
(status, body, headers).
"""

from server import rules
from server.admin_auth import NO_STORE, refusal
from server.guesses import at_rank
from server.leaderboard import PLACEHOLDER, name_expr, served, standings

# A paste that ran away is not a note; the length is the only thing refused.
MAX_NOTE = 500
MAX_NAME = 80

# What a board-row write may set. Each is written only when the body carries
# it, so a star click leaves the note alone and a note save leaves the star.
MARKS = ("note", "private_name", "starred")

# Bounds rather than none, so a response cannot grow without limit once the game
# does. Plays are five rows a player, so 2000 is 400 players on one date.
PLAYER_ROWS = 500
PLAY_ROWS = 2000

# Most recent first: the reason to open the list is somebody who just turned up.
# LEFT JOIN, so a player nobody has named is a row with two nulls, not no row.
PLAYERS = f"""
  SELECT p.player_id,
         {name_expr("p.player_id")} AS name,
         n.alias, n.note,
         COUNT(DISTINCT p.date) AS days,
         SUM(p.points) AS points,
         MAX(p.played_at) AS last_played
    FROM plays p
    LEFT JOIN players n ON n.player_id = p.player_id
   GROUP BY p.player_id
   ORDER BY last_played DESC
   LIMIT ?"""

# `answers` is an inner join because 0004 made plays.image reference it.
# `round_days` is a LEFT JOIN because old plays sit on images never scheduled
# under their date, and they are the games somebody is most likely asking about.
# Ordered so grouping is one pass and rounds arrive in the order they were dealt.
PLAYS = f"""
  SELECT p.player_id,
         {name_expr("p.player_id")} AS name,
         n.alias, n.note,
         d.position, p.image, p.km, p.points, p.guess_lat, p.guess_lng,
         a.lat, a.lng, a.state
    FROM plays p
    JOIN answers a ON a.image = p.image
    LEFT JOIN players n ON n.player_id = p.player_id
    LEFT JOIN round_days d ON d.date = p.date AND d.image = p.image
   WHERE p.date = ?
   ORDER BY p.player_id, d.position
   LIMIT ?"""

ROUND_FIELDS = (
    "position", "image", "state", "km", "points",
    "guess_lat", "guess_lng", "lat", "lng",
)  # fmt: skip


def note_problem(note) -> str | None:
    """What is wrong with a submitted note, or None. Absent and empty both mean
    clear it, so a page can send an emptied field without a second shape."""
    if not isinstance(note, str):
        return "a note must be a string"
    if len(note) > MAX_NOTE:
        return f"a note is at most {MAX_NOTE} characters"
    return None


def _note_of(body: dict):
    # Absent and null both mean empty, as `?? ''` has it; anything else is
    # judged by note_problem.
    note = body.get("note")
    return "" if note is None else note


async def save_note(db, player_id: str, note: str) -> str | None:
    """Sets `note` and nothing else -- not even when the row is created by it --
    and returns what is now stored, None for a cleared one."""
    await db.execute(
        "INSERT INTO players (player_id, note) VALUES (?, NULLIF(?, '')) "
        "ON CONFLICT (player_id) DO UPDATE SET "
        "note = excluded.note, updated_at = datetime('now')",
        player_id,
        note,
    )
    return note or None


def marks_problem(body: dict) -> str | None:
    """What is wrong with a board-row write, or None."""
    if not any(k in body for k in MARKS):
        return "expected any of {note, private_name, starred}"
    if "note" in body and (problem := note_problem(_note_of(body))):
        return problem
    name = body.get("private_name")
    if name is not None and not isinstance(name, str):
        return "a name must be a string"
    if name and len(name) > MAX_NAME:
        return f"a name is at most {MAX_NAME} characters"
    if "starred" in body and not isinstance(body["starred"], bool):
        return "starred must be true or false"
    return None


async def save_marks(db, player_id: str, body: dict) -> None:
    """Upserts the marks the body carries and no others. An empty note or name
    clears it, as an emptied field means."""
    cols = [k for k in MARKS if k in body]
    vals = [int(body[k]) if k == "starred" else (body[k] or "") for k in cols]
    holes = ", ".join("?" if k == "starred" else "NULLIF(?, '')" for k in cols)
    sets = ", ".join(f"{k} = excluded.{k}" for k in cols)
    await db.execute(
        f"INSERT INTO players (player_id, {', '.join(cols)}) VALUES (?, {holes}) "
        f"ON CONFLICT (player_id) DO UPDATE SET {sets}, updated_at = datetime('now')",
        player_id,
        *vals,
    )


async def read_marks(db, player_id: str) -> dict:
    row = await db.fetchone(
        "SELECT note, private_name, starred FROM players WHERE player_id = ?",
        player_id,
    )
    if not row:
        return {"note": None, "private_name": None, "starred": False}
    return {**row, "starred": bool(row["starred"])}


async def read_handle(db, player_id: str) -> str | None:
    """The name the player last drew, whatever alias the board shows over it --
    the second half of leaderboard.name_expr, as a point lookup."""
    row = await db.fetchone(
        "SELECT handle FROM plays WHERE player_id = ? AND handle IS NOT NULL "
        "ORDER BY played_at DESC, rowid DESC LIMIT 1",
        player_id,
    )
    return row["handle"] if row else None


async def players(db, who) -> tuple[int, dict, dict]:
    """GET /admin/players"""
    if refused := refusal(who):
        return refused
    return 200, {"players": await db.fetchall(PLAYERS, PLAYER_ROWS)}, NO_STORE


async def note_player(db, who, body) -> tuple[int, dict, dict]:
    """POST /admin/players {player_id, note}"""
    if refused := refusal(who):
        return refused
    b = body if isinstance(body, dict) else {}
    player_id, note = b.get("player_id"), _note_of(b)
    if not isinstance(player_id, str) or not player_id:
        return 400, {"error": "expected {player_id, note}"}, NO_STORE
    if problem := note_problem(note):
        return 400, {"error": problem}, NO_STORE
    # An id that never played is a typo or a stale copy, and a row for it would
    # never show on a list built from plays.
    if not await db.fetchone(
        "SELECT 1 FROM plays WHERE player_id = ? LIMIT 1", player_id
    ):
        return 404, {"error": "no plays recorded for that player"}, NO_STORE
    return (
        200,
        {"player_id": player_id, "note": await save_note(db, player_id, note)},
        NO_STORE,
    )


def group(rows: list[dict], capped: bool) -> list[dict]:
    """Rows into one entry per player, highest total first.

    A player the LIMIT cut in half is dropped rather than shown short: the total
    is the lookup key -- matched against a score in a screenshot -- so a game
    missing a round is a wrong answer, not a partial one. Only the last group
    can be cut, since rows arrive grouped."""
    out: list[dict] = []
    for row in rows:
        if not out or out[-1]["player_id"] != row["player_id"]:
            out.append(
                {
                    "player_id": row["player_id"],
                    "name": row["name"],
                    "alias": row["alias"],
                    "note": row["note"],
                    "total": 0,
                    "rounds": [],
                }
            )
        out[-1]["total"] += row["points"]
        out[-1]["rounds"].append({k: row[k] for k in ROUND_FIELDS})
    if capped and out:
        out.pop()
    return sorted(out, key=lambda p: -p["total"])


async def plays(db, who, params) -> tuple[int, dict, dict]:
    """GET /admin/plays?date=YYYY-MM-DD -- who is behind a score: collisions on a
    day are likely, and the pins beside each total are what tell them apart."""
    if refused := refusal(who):
        return refused
    date = params.get("date")
    if not rules.is_calendar_date(date):
        return 400, {"error": "expected ?date=YYYY-MM-DD"}, NO_STORE
    rows = await db.fetchall(PLAYS, date, PLAY_ROWS)
    return (
        200,
        {"date": date, "players": group(rows, len(rows) == PLAY_ROWS)},
        NO_STORE,
    )


async def _board_row(db, who, params, now):
    """The row a board+rank names, resolved by the same at_rank() the public
    drilldown uses -- a second answer to "who is #2" would put a note on the
    wrong person. Returns (refusal, None) or (None, found)."""
    if refused := refusal(who):
        return refused, None
    board = params.get("board") or "daily"
    found = await at_rank(db, board, params, now)
    if "error" in found:
        return (found["status"], {"error": found["error"]}, NO_STORE), None
    return None, {**found, "board": board}


def _shape(found: dict, marks: dict, handle: str | None) -> dict:
    # The raw name, not the board's collision-numbered label: it doubles as the
    # check that the rank still names who the caller meant. The handle is the
    # name under an alias -- owner-only here, never on the public board rows.
    return {
        "board": found["board"],
        "period": found["period"],
        "rank": found["rank"],
        "name": found["row"]["name"] or PLACEHOLDER,
        "handle": handle,
        **marks,
    }


async def board_note(db, who, params, now=None) -> tuple[int, dict, dict]:
    """GET /admin/board-note?board=&rank=[&date=|&month=] -- the note against one
    board row, for a surface that holds no player id and must not."""
    refused, found = await _board_row(db, who, params, now)
    if refused:
        return refused
    player_id = found["row"]["player_id"]
    marks, handle = await read_marks(db, player_id), await read_handle(db, player_id)
    return 200, _shape(found, marks, handle), NO_STORE


async def set_board_note(db, who, params, body, now=None) -> tuple[int, dict, dict]:
    """POST /admin/board-note, same query, any of {note, private_name, starred}.
    Answers in the read's shape."""
    refused, found = await _board_row(db, who, params, now)
    if refused:
        return refused
    b = body if isinstance(body, dict) else {}
    if problem := marks_problem(b):
        return 400, {"error": problem}, NO_STORE
    player_id = found["row"]["player_id"]
    await save_marks(db, player_id, b)
    marks, handle = await read_marks(db, player_id), await read_handle(db, player_id)
    return 200, _shape(found, marks, handle), NO_STORE


async def board_marks(db, who, params, now=None) -> tuple[int, dict, dict]:
    """GET /admin/board-marks?board=[&date=|&month=] -- every row of a board
    with the owner's marks on it, as [label, private_name, starred], so a
    surface showing the public board can relabel and star it. The label is
    there to be matched against the public row: a running board can reorder
    between two reads, and a mark must not slide onto the row below."""
    if refused := refusal(who):
        return refused
    board = params.get("board") or "daily"
    if board not in ("daily", "monthly"):
        return 400, {"error": "board must be daily or monthly"}, NO_STORE
    period, _, error = await served(db, board, params, now)
    if error:
        return 400, {"error": error}, NO_STORE
    results, names = await standings(db, board, period)
    ids = [r["player_id"] for r in results]
    marked = (
        {
            m["player_id"]: m
            for m in await db.fetchall(
                "SELECT player_id, private_name, starred FROM players "
                f"WHERE player_id IN ({', '.join('?' * len(ids))})",
                *ids,
            )
        }
        if ids
        else {}
    )
    rows = [
        [
            name,
            marked.get(pid, {}).get("private_name"),
            bool(marked.get(pid, {}).get("starred")),
        ]
        for name, pid in zip(names, ids, strict=True)
    ]
    return 200, {"board": board, "period": period, "rows": rows}, NO_STORE
