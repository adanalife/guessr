// GET /api/recap?date=YYYY-MM-DD&r=<token> -- somebody else's finished game:
// their five pins, the five answers, and how far apart they were.
//
// The share string is deliberately spoiler-free -- five coloured squares that
// say how a game went and nothing about where it was. This is the other half,
// for after: a player who wants to show a friend *how* they got 23,440 has
// nothing to send but a screenshot, and a screenshot cannot be zoomed into or
// argued with.
//
// Two rules keep it from being a way to read ahead:
//
//   The date must be closed. Everything here is an answer key, so a link to a
//   day still in play would spoil it for whoever opens it -- the one person the
//   sender was not thinking about. Closed everywhere, not merely over where the
//   sender lives; the play window spans UTC+14 to UTC-12.
//
//   The token names one player on one date, and is a hash rather than their id
//   (see _recap.mjs). Nothing here can be turned back into the credential that
//   would let the reader play as them.
//
// What it will not do is invent history: a game recorded before guesses were
// stored comes back with its scores and null coordinates, and the page draws
// those rounds without a line. Showing a plausible pin would be worse than
// showing none.
import { isClosed, playWindow } from '../../web/daily.js';
import { json, DATE } from '../_json.mjs';
import { nameExpr, PLACEHOLDER } from '../_names.mjs';
import { playerFor } from '../_recap.mjs';

// A finished day cannot change -- its schedule is frozen, its plays are
// first-write-wins, and it is past its close -- so a recap of one is the same
// bytes forever. The only thing that can move is the player's name.
const CACHE = { 'cache-control': 'public, max-age=3600' };

export async function onRequestGet({ request, env }) {
  const params = new URL(request.url).searchParams;
  const date = params.get('date'), token = params.get('r') || '';
  if (!date || !DATE.test(date)) {
    return json({ error: 'expected ?date=YYYY-MM-DD&r=<token>' }, 400);
  }

  // `closes` goes back with the refusal so the page can say how long the wait
  // is rather than only that there is one. A future date has a close too, and it
  // is honest for the same reason -- that game has not been played yet either.
  if (!isClosed(date)) {
    return json({
      error: 'that day is still being played',
      closes: playWindow(date).closes,
    }, 403);
  }

  const playerId = await playerFor(env, date, token);
  // One message for a token that matches nobody, whether it was mistyped,
  // truncated by whatever pasted it, or belongs to a player who has since been
  // merged into another id by /api/link. The reader can do nothing about any of
  // them except ask for the link again.
  if (!playerId) return json({ error: 'no game found for that link' }, 404);

  // round_days first, so the rounds come back in the order they were played and
  // the numbers on the map match the ones on the contact sheet. An inner join to
  // plays drops the rounds this player never answered -- a recap shows the game
  // they had, which is sometimes three rounds and a night's sleep.
  const { results: rounds } = await env.ANSWERS
    .prepare(`SELECT d.image, a.lat, a.lng, a.state, a.filmed,
                     p.km, p.points, p.guess_lat, p.guess_lng
                FROM round_days d
                JOIN plays p ON p.date = d.date AND p.image = d.image AND p.player_id = ?
                JOIN answers a ON a.image = d.image
               WHERE d.date = ?
               ORDER BY d.position`)
    .bind(playerId, date)
    .all();

  // playerFor only answers with a player that has rows on this date, so an empty
  // result means the schedule went missing underneath them rather than that the
  // link was wrong -- a round deleted from round_days, or answers never seeded.
  if (!rounds.length) return json({ error: 'that game cannot be rebuilt' }, 404);

  // A bare SELECT with no FROM: the whole statement is the name expression, so
  // the shared rule needs no table to hang off and ?1 is bound once for both
  // halves of it.
  const named = await env.ANSWERS
    .prepare(`SELECT ${nameExpr('?1')} AS name`)
    .bind(playerId)
    .first();

  return json({
    date,
    name: named?.name || PLACEHOLDER,
    total: rounds.reduce((sum, r) => sum + r.points, 0),
    rounds,
  }, 200, CACHE);
}
