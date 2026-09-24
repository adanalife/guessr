// GET /admin/plays?date=YYYY-MM-DD -- one date's games, player by player, with
// every pin beside the truth it was aiming at.
//
// The question it answers is "who is this": a score turns up in a screenshot
// with no name on it, and the only handle on it is the number. So the key is the
// score plus the date, not the player -- which means this cannot be a lookup at
// all, it has to be a list to scan. Collisions on a given day are likely at this
// many players, so even an exact match is a shortlist rather than an answer, and
// what settles it is the guesses: two people who both scored 21,340 did not both
// drop a pin in the same wrong Portland.
//
// Everything here already exists in the tables -- `plays` carries the per-round
// result and the pin since 0003, `answers` the truth -- so this is a query and a
// page, and nothing about it is a schema change.
//
// Same gate as the rest of this directory: _middleware.js has already proved who
// the caller is, and what is left is whether the deployment this landed on is
// one this code recognises. The response carries private notes, so that matters
// as much here as it does on /admin/players.
import { DATE, json } from '../_json.mjs';
import { nameExpr } from '../_names.mjs';
import { unknownTier } from './_tier.js';

// Rows, not players -- a day is five per player, so this is 400 players and the
// game is nowhere near that. A bound rather than none, for the reason
// /admin/players has one: the page must not be handed a response that grows
// without limit once it is.
const ROWS = 2000;

// Every play on the date, with the pin, the truth and whatever is known about
// who dropped it.
//
// `answers` is an inner join because migration 0004 made it one: `plays.image`
// references `answers(image)`, so a play whose answer row is missing cannot
// exist. `round_days` is a LEFT JOIN for the opposite reason -- plays sit on
// images that were never scheduled under this date, some predating `round_days`
// entirely, and an inner join there would quietly drop exactly the old games
// somebody is most likely to be asking about.
//
// The name comes from nameExpr like every other view: an alias set by hand wins,
// and reassembling that rule here out of the two columns beside it is the drift
// that expression exists to prevent.
//
// Ordered by player and then position so the grouping below is a single pass,
// and so a game's rounds arrive in the order the player saw them.
export const query = `
  SELECT p.player_id,
         ${nameExpr('p.player_id')} AS name,
         n.alias, n.note,
         d.position, p.image, p.km, p.points, p.guess_lat, p.guess_lng,
         a.lat, a.lng, a.state
    FROM plays p
    JOIN answers a ON a.image = p.image
    LEFT JOIN players n ON n.player_id = p.player_id
    LEFT JOIN round_days d ON d.date = p.date AND d.image = p.image
   WHERE p.date = ?
   ORDER BY p.player_id, d.position
   LIMIT ?`;

// Rows into one entry per player, totalling as it goes.
//
// A player cut in half by the LIMIT is dropped rather than shown short: the
// total is the whole lookup key, so a game missing its fifth round is not a
// partial answer but a wrong one -- it would fail to match the number in the
// screenshot, or worse, match a different player's. Only the last group can be
// cut, since the rows arrive grouped.
export function group(rows, capped) {
  const players = [];
  for (const row of rows) {
    let player = players[players.length - 1];
    if (player?.player_id !== row.player_id) {
      player = {
        player_id: row.player_id,
        name: row.name,
        alias: row.alias,
        note: row.note,
        total: 0,
        rounds: [],
      };
      players.push(player);
    }
    player.total += row.points;
    player.rounds.push({
      position: row.position,
      image: row.image,
      state: row.state,
      km: row.km,
      points: row.points,
      guess_lat: row.guess_lat,
      guess_lng: row.guess_lng,
      lat: row.lat,
      lng: row.lng,
    });
  }
  if (capped) players.pop();
  // Highest first: the thing being looked up is a number, so a list sorted by it
  // is one somebody can scan down to find it.
  return players.sort((a, b) => b.total - a.total);
}

export async function onRequestGet({ request, env }) {
  const url = new URL(request.url);

  // Before the date is parsed, so a refusing tier answers every request here the
  // same way and the shape of the refusal says nothing.
  if (await unknownTier(env, url)) {
    return json({ error: 'the score lookup is not available on this tier' }, 403);
  }

  const date = url.searchParams.get('date');
  if (!date || !DATE.test(date)) {
    return json({ error: 'expected ?date=YYYY-MM-DD' }, 400);
  }

  const { results } = await env.ANSWERS.prepare(query).bind(date, ROWS).all();

  // no-store, for the same reason /admin/players is: this response carries the
  // private note against every player on it, and a shared cache is the one place
  // that has no business sitting.
  return json(
    { date, players: group(results, results.length === ROWS) },
    200,
    { 'cache-control': 'no-store' },
  );
}
