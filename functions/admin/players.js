// GET /admin/players -- everyone who has played, so a note can be put against
// one of them. POST /admin/players {player_id, note} -- put it there.
//
// The note is the private half of a `players` row: who somebody actually is, for
// whoever is reading the stats, served by no endpoint the game exposes. Setting
// one was a `task player:prod ID=... NOTE=...` away, which meant knowing the id
// first -- and the only place an id appears is a stats query printing it beside
// a score. This is that lookup and that write in one screen: the ids come with
// the plays they belong to, so recognising a regular is a matter of finding the
// row that looks like them rather than copying a UUID between two terminals.
//
// The alias is deliberately not editable here. It is published -- it replaces
// that player's own name on every board and on the stream overlay the moment it
// is set -- so it is a different decision made at a different moment, and the
// task that writes it is still the way to make it.
import { json, readJson } from '../_json.mjs';
import { nameExpr } from '../_names.mjs';
import { unknownTier } from './_tier.js';

const refusal = async (env, url) =>
  (await unknownTier(env, url))
    ? json({ error: 'the player list is not available on this tier' }, 403)
    : null;

// How many players come back. Enough that the answer is "all of them" for a game
// this size, and a bound rather than none so the page cannot be handed a
// response that grows without limit once it is not.
const ROWS = 500;

// Who has played, most recent first, with whatever is already known about them.
//
// Ordered by last play rather than by score, because the reason to open this page
// is somebody who turned up -- a regular from last night's stream, a friend who
// says they played. A high score from March is a worse lead than a game from an
// hour ago.
//
// `players` is joined for `alias` and `note`, and the name comes from nameExpr
// anyway: what renders for a player is one expression every view is built from,
// and reassembling it here out of the two columns beside it is exactly the drift
// that expression exists to prevent.
//
// LEFT JOIN, so a player nobody has named is a row with two nulls rather than no
// row -- an inner join here would list only the people already known, which is
// the opposite of what this is for.
export const query = `
  SELECT p.player_id,
         ${nameExpr('p.player_id')} AS name,
         n.alias, n.note,
         COUNT(DISTINCT p.date) AS days,
         SUM(p.points) AS points,
         MAX(p.played_at) AS last_played
    FROM plays p
    LEFT JOIN players n ON n.player_id = p.player_id
   GROUP BY p.player_id
   ORDER BY last_played DESC
   LIMIT ?`;

export async function onRequestGet({ request, env }) {
  const url = new URL(request.url);
  const refused = await refusal(env, url);
  if (refused) return refused;

  const { results } = await env.ANSWERS.prepare(query).bind(ROWS).all();

  // no-store, for the reason a note exists: this response carries the private
  // half of every row on it, and a shared or proxy cache is the one place it has
  // no business sitting.
  return json({ players: results }, 200, { 'cache-control': 'no-store' });
}

// A note is prose about a person, and the length is the only thing worth
// refusing: a paste that ran away is not a note, and the column is read by
// people rather than by anything that would trim it.
const MAX_NOTE = 500;

export async function onRequestPost({ request, env }) {
  const url = new URL(request.url);
  const refused = await refusal(env, url);
  if (refused) return refused;

  const body = await readJson(request);
  const playerId = body?.player_id;
  // Absent and empty are the same instruction -- clear it -- so the page can
  // send an emptied field without a second shape for "delete".
  const note = body?.note ?? '';
  if (typeof playerId !== 'string' || !playerId || typeof note !== 'string') {
    return json({ error: 'expected {player_id, note}' }, 400);
  }
  if (note.length > MAX_NOTE) {
    return json({ error: `a note is at most ${MAX_NOTE} characters` }, 400);
  }

  // A player id that has never played is a mistyped or stale one, and writing it
  // would leave a row naming nobody -- invisible from here afterwards, since this
  // page lists players by their plays. Refusing says which of the two happened.
  const played = await env.ANSWERS
    .prepare('SELECT 1 FROM plays WHERE player_id = ? LIMIT 1')
    .bind(playerId)
    .first();
  if (!played) return json({ error: 'no plays recorded for that player' }, 404);

  // Only `note` is touched, and the conflict clause is why this is not the task's
  // statement: that one writes both columns from its two arguments, so running it
  // to set a note would take down a published alias with it.
  await env.ANSWERS
    .prepare(`INSERT INTO players (player_id, note) VALUES (?, NULLIF(?, ''))
              ON CONFLICT (player_id) DO UPDATE SET
                note = excluded.note,
                updated_at = datetime('now')`)
    .bind(playerId, note)
    .run();

  return json({ player_id: playerId, note: note || null }, 200,
    { 'cache-control': 'no-store' });
}
