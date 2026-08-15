// GET /api/day -- what a date's game is: five rounds, in the order they play.
//
// The draw is a stored fact rather than a function of the pool, which is what
// makes two things true: a regeneration cannot reshuffle a day somebody is
// halfway through, and a daily player never meets the same round twice.
//
// It hands back image names and nothing else. The easy-to-hard ramp is applied
// when a date is scheduled, so the order the rounds arrive in *is* the ramp and
// there is no difficulty score left to send. The coordinates live one table
// over, and /api/score is the only thing that reads them.
import { ROUNDS_PER_GAME, isOpen, lastClosedDate } from '../../web/daily.js';
import { DATE, json } from '../_json.mjs';

export async function onRequestGet({ request, env }) {
  const params = new URL(request.url).searchParams;
  if (params.has('practice')) return practice(env);

  const date = params.get('date');
  if (!date || !DATE.test(date)) {
    return json({ error: 'expected ?date=YYYY-MM-DD, or ?practice' }, 400);
  }

  // The entire gate against reading ahead. The server is the only thing that
  // knows next month's five, so refusing to say is the whole of the protection.
  // Up to three dates are open at once (the play window spans UTC+14 to UTC-12),
  // and everything already closed stays readable so a finished game can be
  // looked at again.
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

// Practice: rounds from days that are over, and only those. Every round in the
// pool belongs to some date, so drawing over the whole of it would hand out a
// date nobody has played yet -- a spoiler rather than practice.
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
