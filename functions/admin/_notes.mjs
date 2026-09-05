// Writing a player's note, as one statement both admin routes are built from.
//
// The rule that matters is what a note write must NOT touch. `players` holds two
// columns and only one of them is private: `alias` is published -- it replaces
// that player's own name on every board and on the stream overlay the moment it
// is set -- while `note` is served by nothing. So a note write sets `note` and
// leaves `alias` exactly where it was, including when the row is created by a
// note and when the note is later cleared.
//
// Written out twice it would drift, and the drift is silent: the alias comes
// down, the boards go back to a wordlist pair, and nothing says why. That is
// also why `task player:prod`'s statement is not the one either route uses --
// it writes both columns from its two arguments, by design, because setting a
// name is what it is for.
//
// Underscore-prefixed, so Pages leaves it out of the routing table.

// A note is prose about a person, and the length is the only thing worth
// refusing: a paste that ran away is not a note, and the column is read by
// people rather than by anything that would trim it.
export const MAX_NOTE = 500;

// What is wrong with a submitted note, or null when nothing is. Absent and empty
// are the same instruction -- clear it -- so a page can send an emptied field
// without a second shape for "delete".
export const noteProblem = note =>
  typeof note !== 'string' ? 'a note must be a string'
    : note.length > MAX_NOTE ? `a note is at most ${MAX_NOTE} characters`
      : null;

// Returns what is now stored, which is null for a cleared one.
export async function saveNote(env, playerId, note) {
  await env.ANSWERS
    .prepare(`INSERT INTO players (player_id, note) VALUES (?, NULLIF(?, ''))
              ON CONFLICT (player_id) DO UPDATE SET
                note = excluded.note,
                updated_at = datetime('now')`)
    .bind(playerId, note)
    .run();
  return note || null;
}

// What is already there, so a surface can show it before overwriting it. A
// player with no row has no note, which reads the same as an empty one.
export const readNote = async (env, playerId) =>
  (await env.ANSWERS
    .prepare('SELECT note FROM players WHERE player_id = ?')
    .bind(playerId)
    .first())?.note ?? null;
