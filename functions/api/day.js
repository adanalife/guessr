// GET /api/day -- what a date's game is: five rounds, in the order they play.
//
// This replaced a committed manifest plus a seeded shuffle that both the page
// and the scorer re-ran from it. The transport is the least of the difference.
// The draw is a stored fact now, which means a regeneration cannot reshuffle a
// day somebody is halfway through, and a daily player stops meeting the same
// round twice -- under a shuffle over a growing pool they saw a repeat roughly
// every other game by day 90.
//
// It hands back image names and nothing else. `median_km` used to ride along in
// the manifest and had exactly one consumer, the easy-to-hard ramp; the ramp is
// applied when a date is scheduled now, so the order the rounds arrive in *is*
// the ramp and there is nothing left to send. The coordinates live one table
// over, and /api/score is still the only thing that reads them.
import { ROUNDS_PER_GAME, isOpen, lastClosedDate } from '../../web/daily.js';
import { DATE, json } from '../_json.mjs';

export async function onRequestGet({ request, env }) {
  const params = new URL(request.url).searchParams;
  if (params.has('practice')) return practice(env);

  const date = params.get('date');
  if (!date || !DATE.test(date)) {
    return json({ error: 'expected ?date=YYYY-MM-DD, or ?practice' }, 400);
  }

  // The entire gate against reading ahead, and it only exists because the draw
  // moved here. While the schedule was a seeded shuffle in a file the browser
  // already had, anyone could derive next month's five and there was nothing to
  // refuse; now the server is the only thing that knows, so this is worth more
  // than the check it replaces. Up to three dates are open at once (the play
  // window spans UTC+14 to UTC-12), and everything already closed stays readable
  // so a finished game can be looked at again.
  if (!isOpen(date) && date > lastClosedDate()) {
    return json({ error: 'that day has not opened yet' }, 403);
  }

  const { results } = await env.ANSWERS
    .prepare('SELECT image FROM round_days WHERE date = ? ORDER BY position')
    .bind(date)
    .all();

  // A date inside the window with no rounds means the schedule ran dry -- the
  // generator has not been run lately, or its horizon ended here. Distinct from
  // the 403 above so the page can say which happened, and so smoke.sh can tell a
  // tier that is unplayable from one that is merely being asked about tomorrow.
  if (!results.length) {
    return json({ error: 'no game is scheduled for that date' }, 404);
  }

  // A date's five are frozen from the moment it opens: the generator schedules
  // two days out and the admin endpoints refuse anything already open, so no
  // date that can be requested here can still change. That is what makes caching
  // it worth doing at all -- and it is the whole reason those two rules exist.
  return json({ date, rounds: results }, 200, {
    'cache-control': 'public, max-age=86400',
  });
}

// Practice: rounds from days that are over. It has to be server-side now for a
// reason that did not exist before -- the pool used to be a flat list of every
// round, and drawing from it under a schedule would hand out a date nobody has
// played yet, which is a spoiler rather than practice.
async function practice(env) {
  const { results } = await env.ANSWERS
    .prepare(`SELECT image FROM round_days
              WHERE date <= ? ORDER BY random() LIMIT ?`)
    .bind(lastClosedDate(), ROUNDS_PER_GAME)
    .all();

  if (!results.length) {
    return json({ error: 'nothing has finished playing yet' }, 404);
  }
  // Fewer than five early on, when barely any dates have closed. A short game is
  // a better answer than no practice at all, and the page reads its length from
  // what it is given rather than assuming five.
  //
  // no-store, because the point is a different draw every time.
  return json({ date: null, rounds: results }, 200, { 'cache-control': 'no-store' });
}
