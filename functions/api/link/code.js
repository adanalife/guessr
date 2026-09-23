// POST /api/link/code {player_id} -- a short code another device can type in to
// join this player (see claim.js for the other half).
//
// /api/link needs both ids in one hand, which a URL fragment can only deliver
// to a browser that opens links: a Home Screen install keeps its own storage,
// and the native app has no way to receive one at all. A code goes the other
// way round -- this device asks, a person carries eight letters to the other
// screen, and the server is the only party that ever holds both ids.
//
// Anyone can ask for a code against any id, which gives them nothing: a code
// only ever makes its *claimer* play as the id behind it, and asking for one
// already requires knowing that id -- the same secret /api/link and /api/score
// treat as the whole credential.
import { isPlayerId } from '../../_scoring.mjs';
import { json, readJson } from '../../_json.mjs';

// No 0/O or 1/I, since the whole point is being read off one screen and typed
// into another. 32 letters, so a random byte masked to five bits picks one
// uniformly -- no modulo bias to reason about.
export const ALPHABET = 'ABCDEFGHJKLMNPQRSTUVWXYZ23456789';
export const LENGTH = 8;

// SQLite's clock, in both runtimes and in the one format expires_at is stored
// in, so expiry is a plain string comparison and neither handler reads a clock
// of its own.
export const NOW = "strftime('%Y-%m-%dT%H:%M:%SZ', 'now')";
// Expired codes are swept by the next issue or claim rather than by a schedule:
// the table only ever holds codes minutes old, so a sweep is a handful of rows.
// The same statement drops this player's earlier codes, so one player has at
// most one live code and asking again replaces it.
export const SWEEP_CODES = `DELETE FROM link_codes WHERE player_id = ? OR expires_at <= ${NOW}`;
export const ISSUE = `INSERT INTO link_codes (code, player_id, expires_at)
  VALUES (?, ?, strftime('%Y-%m-%dT%H:%M:%SZ', 'now', '+10 minutes'))
  RETURNING expires_at`;

export function newCode() {
  const bytes = crypto.getRandomValues(new Uint8Array(LENGTH));
  return Array.from(bytes, b => ALPHABET[b & 31]).join('');
}

export async function onRequestPost({ request, env }) {
  const body = await readJson(request);
  const playerId = body?.player_id;
  if (!isPlayerId(playerId)) return json({ error: 'expected {player_id}' }, 400);

  await env.ANSWERS.prepare(SWEEP_CODES).bind(playerId).run();
  const code = newCode();
  const row = await env.ANSWERS.prepare(ISSUE).bind(code, playerId).first();
  return json({ code, expires_at: row.expires_at });
}
