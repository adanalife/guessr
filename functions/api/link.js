// POST /api/link -- fold one browser's plays into another's, so a player who
// plays on a phone and a desktop places once instead of twice.
//
// There is no account to log into, and adding one for this would be the whole
// apparatus (an email, a session, a way back in when it is lost) to solve a
// problem that is one row rewrite. The player id already *is* the credential:
// it is minted in the browser, never leaves it, and never appears in a response
// -- /api/leaderboard returns names and points and deliberately not ids. So
// holding both ids is proof enough of holding both browsers, and the page hands
// the id to the other device in a URL fragment.
//
// The consequence, worth being plain about: anyone who learns a player's id can
// point this at it and take that history. That is the same exposure the id
// already carried -- knowing it lets you post plays as that player -- and the
// mitigation is the same one, which is that it is a secret with no path out of
// the browser that holds it.
import { isPlayerId } from '../_scoring.mjs';

const json = (body, status = 200) =>
  new Response(JSON.stringify(body), {
    status,
    headers: { 'content-type': 'application/json' },
  });

// Two statements, because the second is what the first leaves behind. A player
// who answered the same round on the same date from both browsers has two rows
// that would collide on (date, player_id, image); OR IGNORE keeps the one
// already under `to` -- first write wins, same rule the table exists to enforce
// -- and skips the mover, which SWEEP then clears out. Without it the old id
// keeps a stray row and the merge silently isn't one.
//
// Exported for test_link.mjs, which runs them against a real SQLite over the
// real schema rather than a second copy of the logic. Pages only looks for the
// onRequest* exports.
export const MOVE = 'UPDATE OR IGNORE plays SET player_id = ? WHERE player_id = ?';
export const SWEEP = 'DELETE FROM plays WHERE player_id = ?';

export async function onRequestPost({ request, env }) {
  let body = null;
  try {
    body = await request.json();
  } catch { /* body stays null */ }

  const from = body?.from, to = body?.to;
  if (!isPlayerId(from) || !isPlayerId(to)) {
    return json({ error: 'expected {from, to}' }, 400);
  }
  // Not an error worth failing on -- a player who opens their own link on the
  // browser that made it has asked for nothing and gets nothing -- but the
  // statements below would delete every row they just moved onto themselves.
  if (from === to) return json({ moved: 0 });

  // One transaction: SWEEP assumes MOVE ran, so a batch that half applied would
  // drop plays rather than move them.
  const [moved] = await env.ANSWERS.batch([
    env.ANSWERS.prepare(MOVE).bind(to, from),
    env.ANSWERS.prepare(SWEEP).bind(from),
  ]);
  return json({ moved: moved.meta.changes });
}
