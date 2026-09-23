// POST /api/link/claim {code, from} -- the device that typed a code in joins the
// player who asked for it: `from`'s plays fold onto that player by the same
// MOVE+SWEEP /api/link runs, and the answer names the id to play as from here on.
//
// ponytail: no rate limit. An eight-letter code over 32 letters is 2^40 values,
// each live for ten minutes, so the ceiling is guesses per second against how
// many codes are live at once: 1,000 a second against one live code is ~35
// years per hit, and the odds scale linearly with live codes. The upgrade when
// that stops being comfortable: a Cloudflare rate-limiting rule on this path
// (no code), then a longer code or a shorter TTL.
import { isPlayerId } from '../../_scoring.mjs';
import { json, readJson } from '../../_json.mjs';
import { MOVE, SWEEP } from '../link.js';
import { ALPHABET, LENGTH, NOW } from './code.js';

const SHAPE = new RegExp(`^[${ALPHABET}]{${LENGTH}}$`);

// Deleting and reading back in one statement is what makes a code single-use:
// two claims racing on one code cannot both get a row. Expired ones match
// nothing, and the sweep beside it clears them out.
export const TAKE = `DELETE FROM link_codes WHERE code = ? AND expires_at > ${NOW}
  RETURNING player_id`;
export const SWEEP_EXPIRED = `DELETE FROM link_codes WHERE expires_at <= ${NOW}`;

// Typed by hand on a phone, so case and the spaces or dashes a person adds to
// keep their place are forgiven. Anything else is a code nobody issued.
export const normalize = code =>
  typeof code === 'string' ? code.replace(/[\s-]/g, '').toUpperCase() : '';

export async function onRequestPost({ request, env }) {
  const body = await readJson(request);
  const code = normalize(body?.code), from = body?.from;
  if (!SHAPE.test(code) || !isPlayerId(from)) {
    return json({ error: 'expected {code, from}' }, 400);
  }

  await env.ANSWERS.prepare(SWEEP_EXPIRED).run();
  const row = await env.ANSWERS.prepare(TAKE).bind(code).first();
  // Unknown, expired and already-claimed are one answer: telling them apart
  // would tell a guesser which codes were ever real.
  if (!row) return json({ error: 'unknown or expired code' }, 404);
  const to = row.player_id;

  // The device that asked for the code typed it into itself: it already is that
  // player, and the pair below would delete every row it just moved onto itself.
  if (from === to) return json({ player_id: to, moved: 0 });

  const [moved] = await env.ANSWERS.batch([
    env.ANSWERS.prepare(MOVE).bind(to, from),
    env.ANSWERS.prepare(SWEEP).bind(from),
  ]);
  return json({ player_id: to, moved: moved.meta.changes });
}
