// GET /admin/upcoming -- every round the schedule still has ahead of it,
// ranked by how distinctive it is rather than by the day it lands on.
//
// The question is whether distinctiveness looks like *interesting*. `mean_cos`
// is the mean cosine distance from a frame to its nearest neighbours in
// embedding space, so a high one means the clip has no near-twins in the corpus
// -- and whether that reads as a good round to play is a judgement nobody can
// make from the number. It has to be watched. The ranking recurs every time the
// pool is regenerated, which is why it is a page and not a one-off query.
//
// Deliberately not folded into /admin/day. That endpoint answers "what is this
// date", one date at a time, and every guard on it is about a date -- a horizon
// read down the same handler would have to opt out of each one. This reads
// across dates and refuses none of them, because there is no date here that has
// not already been through that page.
//
// Same gate as the rest of this directory: _middleware.js has proved who the
// caller is, and what is left is whether this deployment is one the code knows.
import { lastClosedDate } from '../../web/daily.js';
import { json } from '../_json.mjs';
import { unknownTier } from './_tier.js';

// The horizon is a fortnight of five, and a generation run that overshoots is
// the case worth bounding -- not a page somebody scrolls. Rounds, not days, so
// the cap does not depend on the schedule being full.
const ROWS = 200;

// Everything still to come, most distinctive first.
//
// The lower bound is `lastClosedDate()` and not `date('now')`: a guessr date
// stays playable until noon UTC the day after it, so between midnight and noon
// the SQL expression drops a date players are still mid-game on -- which is
// exactly the date most worth looking at. The rule lives in daily.js and is
// imported rather than restated, the way /admin/day imports playWindow.
//
// LEFT JOIN on answers for the reason the day preview has one: a scheduled round
// with no answer row is a rounds push whose answers push never happened, and
// this page showing it as a state-less tile is better than dropping it from a
// list of what is coming.
export const query = `
  SELECT d.date, d.position, d.image, r.mean_cos, r.median_km, r.slug, a.state
    FROM round_days d
    JOIN rounds r ON r.image = d.image
    LEFT JOIN answers a ON a.image = d.image
   WHERE d.date > ?
   ORDER BY r.mean_cos DESC, d.date, d.position
   LIMIT ?`;

export async function onRequestGet({ request, env }) {
  const url = new URL(request.url);
  if (await unknownTier(env, url)) {
    return json({ error: 'the upcoming rounds are not available on this tier' }, 403);
  }

  const since = lastClosedDate();
  const { results } = await env.ANSWERS.prepare(query).bind(since, ROWS).all();

  // `since` rides along so the page can say what "upcoming" meant, rather than
  // leaving a reader to work out why the oldest tile is yesterday's.
  return json({ since, rounds: results }, 200, { 'cache-control': 'no-store' });
}
