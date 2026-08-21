// GET /admin/guesses -- every recorded guess coordinate, for the day preview's
// heat layer.
//
// The pool map says where the game actually was; this is the other half of the
// picture, where players thought it was. Dense heat over a city the game never
// visits is players pattern-matching on vibes; heat that hugs the pool is a
// game being genuinely located. Coordinates only, deliberately: no date, no
// player, no score, so the layer can say "here" and nothing else about anyone.
//
// No tier guard, unlike /admin/day: nothing here is an answer to an unopened
// round, so the Access login in _middleware.js is the whole gate.
import { json } from '../_json.mjs';

export async function onRequestGet({ env }) {
  // The columns are written together or not at all, so one IS NOT NULL filters
  // both -- and with it every play recorded before the columns existed.
  const { results } = await env.ANSWERS
    .prepare('SELECT guess_lat, guess_lng FROM plays WHERE guess_lat IS NOT NULL')
    .all();

  // Bare [lat, lng] pairs: exactly what L.heatLayer takes, and the smallest
  // shape that says where.
  return json(
    { guesses: results.map(r => [r.guess_lat, r.guess_lng]) },
    200,
    { 'cache-control': 'no-store' },
  );
}
