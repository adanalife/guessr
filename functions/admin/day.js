// GET /admin/day?date=YYYY-MM-DD -- a scheduled day's rounds *with* their
// answers, so a day can be looked at before players get it.
//
// This is /api/day with both of its rules inverted, which is why it is a separate
// route rather than a flag on that one. That endpoint refuses a date that has not
// opened, and projects `image` and nothing else because the coordinates live in
// another table so it physically cannot leak one. Both are load-bearing, and
// neither survives a `?preview=1` branch running down the same handler -- the
// guard stops being absolute, and "cannot leak a coordinate" becomes "does not,
// under the conditions currently written".
//
// What stands in for them here is the tier. Staging and the per-PR previews are
// not secret and do not need to be: each holds its own round set, so a schedule
// read off one says nothing about production's until a promotion copies it. So
// the whole gate is "this is not production", and it is a refusal to answer at
// all rather than a narrower answer -- the cheap half of the authenticated
// /admin the round pipeline design asks for, which it does not foreclose.
//
// Seeing the queue is most of the value of an admin view: reject and reorder are
// only worth having once looking is possible, and this is where a wrong
// coordinate or a dud clip gets caught. The alternative place is a real day.
import { isOpen } from '../../web/daily.js';

const json = (body, status = 200, headers = {}) =>
  new Response(JSON.stringify(body), {
    status,
    headers: { 'content-type': 'application/json', ...headers },
  });

const DATE = /^\d{4}-\d{2}-\d{2}$/;

// Where the queue and the answer key may be read. An allowlist rather than
// `tier !== 'production'` so that every way of not knowing -- no version.json, a
// version.json that will not parse, a tier nobody has taught this about -- reads
// as production. That is the direction to be wrong in: the cost of a false
// refusal is that a testing tier needs a line added here, and the cost of a
// false answer is tomorrow's five and where they are.
const TESTING_TIERS = new Set(['staging', 'preview', 'local']);

// Which tier is serving this, as declared by the workflow that deployed it --
// the same web/version.json the About panel reads, fetched through the
// static-asset binding rather than over the network.
//
// Declared rather than inferred from the hostname, for the reason the page
// already records: a Pages alias or a redirect pointed at production would fool
// a hostname test, while the deploying workflow knows for certain. A local `task
// dev` stamps one, because the alternative is this refusing itself on the
// surface it is most useful on.
async function tier(env, url) {
  try {
    const res = await env.ASSETS.fetch(new URL('/version.json', url));
    return res.ok ? (await res.json()).tier : null;
  } catch {
    // No ASSETS binding, or a version.json that is not JSON. Both are "unknown",
    // which TESTING_TIERS answers with a refusal.
    return null;
  }
}

export async function onRequestGet({ request, env }) {
  const url = new URL(request.url);

  // Before the date is even parsed, so production answers everything here the
  // same way and there is nothing to learn from the shape of the refusal.
  if (!TESTING_TIERS.has(await tier(env, url))) {
    return json({ error: 'the day preview is not available on this tier' }, 403);
  }

  const date = url.searchParams.get('date');
  if (!date || !DATE.test(date)) {
    return json({ error: 'expected ?date=YYYY-MM-DD' }, 400);
  }

  // LEFT JOIN on answers, not JOIN: a round scheduled with no answer row is
  // exactly the failure this view should show. It is what a rounds push without
  // the matching answers push looks like, and today it surfaces as every guess
  // on that day coming back "unknown round" -- on a deploy that went green.
  const { results } = await env.ANSWERS
    .prepare(`SELECT d.position, d.image, r.median_km, r.radius_m, r.slug,
                     r.source_ts_sec, a.lat, a.lng, a.state, a.filmed
                FROM round_days d
                JOIN rounds r ON r.image = d.image
                LEFT JOIN answers a ON a.image = d.image
               WHERE d.date = ?
               ORDER BY d.position`)
    .bind(date)
    .all();

  if (!results.length) {
    return json({ error: 'no game is scheduled for that date' }, 404);
  }

  // How far the schedule reaches. The other thing there is no way to see today:
  // the generator lays out the set it just produced and reads no horizon, so
  // "are we covered next week" is currently a question you answer by waiting.
  const through = await env.ANSWERS
    .prepare('SELECT MAX(date) AS date FROM round_days')
    .first();

  // no-store. An unopened day is the one thing here that can still change -- a
  // regeneration or a future reject moves it -- and a cached review of a day
  // that has since been rescheduled is worse than no review.
  return json({
    date,
    open: isOpen(date),
    scheduled_through: through?.date ?? null,
    rounds: results,
  }, 200, { 'cache-control': 'no-store' });
}
