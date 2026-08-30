// GET /api/guesses?board=daily|monthly&rank=N -- the plays behind one board
// row: which round, how far off, and where the pin actually went.
//
// Keyed by rank rather than player_id, because the id is a write credential --
// /api/score records plays under it and /api/link moves a player's whole
// history by it -- so no public response may carry one. A rank is resolved by
// re-running the board query, whose ordering (points DESC, then player_id) is
// deterministic, so the same rank names the same player for as long as the
// board itself holds still.
import { lastClosedDate, monthOf } from '../../web/daily.js';
import { json } from '../_json.mjs';
import { PLACEHOLDER } from '../_names.mjs';
import { query, ROWS } from './leaderboard.js';

const CACHE = { 'cache-control': 'public, max-age=60' };

// One player's plays across a span, in the order they were dealt. The join
// recovers which of the day's five rounds a play answered; LEFT, because a play
// outliving its schedule row should lose its number, not the whole row.
//
// The pin and the clip are both withheld for a date still open. The monthly
// board sums the running month, today included -- and today is a game other
// people have not played yet, so a strong player's pin on an open round is a
// public copy of roughly where the answer is, and the clip key names which
// footage today serves before anyone has been dealt it. Distance and points
// leak nothing without either, so they stay. (`?3` is the last closed date; the
// daily board's span is always at or behind it, so the guard only ever bites on
// the monthly board.)
//
// The image doubles as the clip's public path -- `clips/<slug>-<ms>.mp4` is
// both the R2 key and what /clips/ serves it under -- so a caller holding one
// can play back the footage the guess was made against.
//
// Exported for test_guesses.mjs, same arrangement as the board query above it.
export const guesses = span => `
  SELECT p.date, rd.position, p.km, p.points,
         CASE WHEN p.date <= ?3 THEN p.image END AS image,
         CASE WHEN p.date <= ?3 THEN p.guess_lat END AS guess_lat,
         CASE WHEN p.date <= ?3 THEN p.guess_lng END AS guess_lng
    FROM plays p
    LEFT JOIN round_days rd ON rd.date = p.date AND rd.image = p.image
   WHERE p.player_id = ?2 AND p.date ${span}
   ORDER BY p.date, rd.position`;

export async function onRequestGet({ request, env }) {
  const params = new URL(request.url).searchParams;
  const board = params.get('board') || 'daily';
  if (board !== 'daily' && board !== 'monthly') {
    return json({ error: 'board must be daily or monthly' }, 400, CACHE);
  }
  const rank = Number(params.get('rank'));
  if (!Number.isInteger(rank) || rank < 1 || rank > ROWS) {
    return json({ error: `rank must be 1..${ROWS}` }, 400, CACHE);
  }

  const daily = board === 'daily';
  const period = daily ? lastClosedDate() : monthOf();

  // The board query with the rank as its LIMIT: the row wanted is the last one,
  // and coming up short means the board has no such rank today -- an answer,
  // not an error in the request, hence 404 rather than 400.
  const { results: standings } = await env.ANSWERS
    .prepare(query(daily ? '= ?' : "LIKE ? || '-%'"))
    .bind(period, rank)
    .all();
  if (standings.length < rank) {
    return json({ error: 'no player at that rank' }, 404, CACHE);
  }
  const row = standings[rank - 1];

  const { results } = await env.ANSWERS
    .prepare(guesses(daily ? '= ?1' : "LIKE ?1 || '-%'"))
    .bind(period, row.player_id, lastClosedDate())
    .all();

  // The raw name, not the board's collision-numbered one: numbering is a
  // property of a rendered board, and the caller already holds the label it
  // clicked. This is a cross-check that the rank still names who they meant.
  return json({
    board, period, rank,
    name: row.name || PLACEHOLDER,
    rows: results,
  }, 200, CACHE);
}
