// POST /admin/review {date, reviewed} -- mark that somebody has looked at an
// upcoming day, or take the mark back.
//
// The approve half of a review. Rejecting a round says what is wrong with a
// day; nothing has ever said that a day is *right*, so a schedule reviewed out
// to the horizon and one nobody has opened look identical from every surface
// that reads it -- including the one that decides whether the week ahead needs
// attention.
//
// It gates nothing, on purpose. Generation keeps its three-day lead so review
// stays possible and never required, and a rule that refused to publish an
// unreviewed day would convert a missed evening into a date with no game.
// This route records the fact; what to do about an unreviewed day is a
// person's call.
//
// Its own route rather than a shape on /admin/day's POST, because that one
// means "throw this round out and pay for the replacement", and a handler that
// branches on which keys arrived is one payload typo away from doing the other
// thing.
import { playWindow } from '../../web/daily.js';
import { DATE, json, readJson } from '../_json.mjs';
import { unknownTier } from './_tier.js';

export async function onRequestPost({ request, env }) {
  const url = new URL(request.url);

  // Exactly as gated as the read and the reject beside it, and first for the
  // same reason: a refusing tier answers everything here the same way.
  if (await unknownTier(env, url)) {
    return json({ error: 'the day preview is not available on this tier' }, 403);
  }

  const body = await readJson(request);
  const date = body?.date;
  if (typeof date !== 'string' || !DATE.test(date) || typeof body.reviewed !== 'boolean') {
    return json({ error: 'expected {date, reviewed}' }, 400);
  }

  // The same freeze /admin/day's reject observes, for a reason one step along
  // from it: once a date has opened, its schedule cannot be changed, so a
  // review of it can no longer mean "this is what players will get". Marking
  // history reviewed would read as approval of something nobody could have
  // withheld.
  if (Date.now() >= playWindow(date).opens) {
    return json({ error: `${date} has already opened, so there is nothing left to review` }, 409);
  }

  // Scheduled, before anything is written. A typo'd date would otherwise mark a
  // day that does not exist as reviewed, and the horizon would count it.
  const scheduled = await env.ANSWERS
    .prepare('SELECT 1 FROM round_days WHERE date = ? LIMIT 1')
    .bind(date)
    .first();
  if (!scheduled) return json({ error: `no game is scheduled for ${date}` }, 404);

  await env.ANSWERS
    .prepare(body.reviewed
      ? `INSERT INTO day_reviews (date) VALUES (?)
         ON CONFLICT (date) DO UPDATE SET reviewed_at = datetime('now')`
      : 'DELETE FROM day_reviews WHERE date = ?')
    .bind(date)
    .run();

  // The stored timestamp rather than one made up here, so the page shows what
  // the database holds -- the two would drift by however long the write took,
  // and the one on screen is the one a reviewer would quote.
  const row = await env.ANSWERS
    .prepare('SELECT reviewed_at FROM day_reviews WHERE date = ?')
    .bind(date)
    .first();

  return json({ date, reviewed_at: row?.reviewed_at ?? null },
    200, { 'cache-control': 'no-store' });
}
