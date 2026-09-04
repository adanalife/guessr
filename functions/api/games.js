// POST /api/games -- every daily this player has finished, and a link to the
// ones that are safe to share.
//
// The game keeps no account, so this is the closest thing a player has to a
// record of their own play: the browser only remembers the day it is in the
// middle of, and a device linked in later never saw the days before it. What
// `plays` holds is the whole history, and the player id is what asks for it.
//
// A POST for a read, because the body is where the player id belongs. In a query
// string it would ride into access logs, `Referer` headers on every outbound
// link from the page, and the browser history of a shared laptop -- and this id
// is a credential (see /api/link), so those are the three places it must not go.
import { isPlayerId } from '../_scoring.mjs';
import { isClosed } from '../../web/daily.js';
import { json, readJson } from '../_json.mjs';
import { tokenFor } from '../_recap.mjs';

// A month of daily games. Long enough to find the one worth showing somebody,
// short enough that the response stays a list rather than an archive.
const GAMES = 30;

export async function onRequestPost({ request, env }) {
  const body = await readJson(request);
  const playerId = body?.player_id;
  if (!isPlayerId(playerId)) return json({ error: 'expected {player_id}' }, 400);

  const { results } = await env.ANSWERS
    .prepare(`SELECT date, SUM(points) AS total, COUNT(*) AS rounds
                FROM plays
               WHERE player_id = ?
               GROUP BY date
               ORDER BY date DESC
               LIMIT ?`)
    .bind(playerId, GAMES)
    .all();

  // A token only for a day that has finished playing everywhere. A recap is five
  // answers laid out on a map, so a link to one that is still open is a spoiler
  // for anybody who has not played it yet -- including the person it was sent
  // to. The page turns a missing token into how long the wait is, which it can
  // work out for itself from the closing rule.
  const games = await Promise.all(results.map(async g => ({
    ...g,
    token: isClosed(g.date) ? await tokenFor(playerId, g.date) : null,
  })));

  // no-store: it is one player's own history, keyed on a credential, and there
  // is nothing here worth a shared cache holding.
  return json({ games }, 200, { 'cache-control': 'no-store' });
}
