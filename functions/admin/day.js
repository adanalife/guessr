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
// What stands in for them is the login: _middleware.js puts Cloudflare Access in
// front of this whole directory, so a request that reaches this handler has
// already proved who it is. What is left here is the narrower question of
// whether the deployment it landed on is one this code recognises at all.
//
// Seeing the queue is most of the value of an admin view: reject and reorder are
// only worth having once looking is possible, and this is where a wrong
// coordinate or a dud clip gets caught. The alternative place is a real day.
import { isOpen, playWindow } from '../../web/daily.js';
import { DATE, json, readJson } from '../_json.mjs';
import { tier } from './_tier.js';

// The tiers this code knows about. Production is one of them: its schedule is
// the one a wrong coordinate actually reaches players through, so the surface
// built to catch that has to work there or it catches it everywhere except where
// it counts.
//
// Still an allowlist rather than nothing, because "which tier is this" has a way
// of coming back unanswerable -- no version.json, a version.json that will not
// parse, a tier nobody has taught this about -- and a deployment this code cannot
// name is one whose Access application it cannot vouch for either. Refusing costs
// a line here when a tier is added; answering costs tomorrow's five and where
// they are.
const KNOWN_TIERS = new Set(['production', 'staging', 'preview', 'local']);

// Shared by both methods, and shared deliberately: a second copy of the
// allowlist is a second thing to remember when a tier is added, and the one that
// gets forgotten is whichever is not being looked at. The write below is exactly
// as gated as the read above it.
const refusal = async (env, url) =>
  KNOWN_TIERS.has(await tier(env, url))
    ? null
    : json({ error: 'the day preview is not available on this tier' }, 403);

export async function onRequestGet({ request, env }) {
  const url = new URL(request.url);

  // Before the date is even parsed, so a refusing tier answers everything here
  // the same way and there is nothing to learn from the shape of the refusal.
  const refused = await refusal(env, url);
  if (refused) return refused;

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

  // How far the schedule reaches, and how much spare there is behind it.
  //
  // The two belong together because either alone reads as healthy while the
  // other is empty. The horizon is what a rejection is paid out of once the
  // queue runs dry -- the POST below gives up the whole furthest-out day for one
  // round -- so a fortnight of schedule with nothing queued is a fortnight that
  // shortens every time somebody clicks Reject. The count is the same one
  // publish.sh reads back after a push, deliberately: two surfaces disagreeing
  // about how many spares exist would be worse than neither showing it.
  //
  // One statement rather than two round trips; the subquery is uncorrelated, so
  // it still answers when round_days is empty.
  const through = await env.ANSWERS
    .prepare(`SELECT MAX(date) AS date,
                     (SELECT COUNT(*) FROM rounds WHERE status = 'queued') AS queued
                FROM round_days`)
    .first();

  // Every round that has an answer, so the page can draw the pool the day came
  // out of. The whole set rather than a summary because it is hundreds of rows
  // of three columns, and because the thing worth seeing is the shape -- one
  // interstate leg or the whole trip -- which is exactly what any aggregate
  // throws away. Rides on this response rather than a route of its own: same
  // gate, same page load, nothing new to protect.
  const { results: pool } = await env.ANSWERS
    .prepare(`SELECT a.lat, a.lng, r.status
                FROM rounds r
                JOIN answers a ON a.image = r.image`)
    .all();

  // no-store. An unopened day is the one thing here that can still change -- a
  // regeneration or a future reject moves it -- and a cached review of a day
  // that has since been rescheduled is worse than no review.
  return json({
    date,
    open: isOpen(date),
    scheduled_through: through?.date ?? null,
    queued: through?.queued ?? 0,
    rounds: results,
    pool,
  }, 200, { 'cache-control': 'no-store' });
}

// POST /admin/day {date, image} -- throw a round out of an upcoming day and pull
// its replacement off the back of the queue.
//
// The verb the viewer above was missing. Seeing that tomorrow's third round is a
// tunnel, or that its coordinates land in a river, is only half of a review; the
// other half is being able to do something about it in the same minute, on the
// one tier where a schedule can still be changed without touching what anybody
// is playing.
//
// `rounds.status` was declared with 'rejected' in the baseline migration for
// exactly this, and nothing wrote it until now. It is not the same fact as "no
// longer in round_days": a round nobody has scheduled yet and a round somebody
// threw out are both absent from the schedule, and the next generation run has
// to be able to place the first and never the second.

// Where a replacement comes from. Queued surplus first -- a generation run that
// produced more rounds than it could place leaves some, and spending those costs
// nothing.
const QUEUED = "SELECT image FROM rounds WHERE status = 'queued' ORDER BY image LIMIT 1";

// With no surplus, the only spare rounds in the database are ones already
// promised to a later date, so a rejection is paid for out of the schedule's
// tail. The whole last day goes back to 'queued' rather than just the one round
// taken: a four-round day is not a day, and leaving one behind would mean the
// horizon quietly reported a date that could never be played.
//
// Ordered by date so the day given up is the furthest out -- the one with the
// most time to be regenerated before anybody would have reached it. Runway is
// renewable; a generation run buys it straight back.
const TAIL = 'SELECT MAX(date) AS date FROM round_days';
const TAIL_ROUNDS = 'SELECT image FROM round_days WHERE date = ? ORDER BY position';

export async function onRequestPost({ request, env }) {
  const url = new URL(request.url);

  // The same gate as the read, and first for the same reason.
  const refused = await refusal(env, url);
  if (refused) return refused;

  const body = await readJson(request);
  const date = body?.date, image = body?.image;
  if (typeof date !== 'string' || !DATE.test(date) || typeof image !== 'string') {
    return json({ error: 'expected {date, image}' }, 400);
  }

  // The schedule is frozen from the moment a date opens, which is the rule the
  // rows for an open date already exist to enforce -- a player halfway through a
  // game cannot have its third round swapped underneath them, and a finished day
  // is the record of what was actually played. `opens` rather than isOpen(),
  // because a date that has closed is past editing too and isOpen() says only
  // that it is not currently live.
  if (Date.now() >= playWindow(date).opens) {
    return json({ error: `${date} has already opened, so its schedule is frozen` }, 409);
  }

  const slot = await env.ANSWERS
    .prepare('SELECT position FROM round_days WHERE date = ? AND image = ?')
    .bind(date, image)
    .first();
  if (!slot) return json({ error: `${image} is not scheduled on ${date}` }, 404);

  // Read, decide, then write once. The decision needs a branch that a batch
  // cannot express, so the reads sit outside the transaction -- which is
  // survivable here and would not be on a player-facing path: this endpoint
  // exists on tiers with one operator, and two simultaneous rejections are not a
  // thing that happens.
  let replacement = await env.ANSWERS.prepare(QUEUED).first();
  const writes = [];
  let unscheduled = null;

  if (!replacement) {
    const tail = await env.ANSWERS.prepare(TAIL).first();
    // Nothing further out to borrow from. Refusing beats emptying the day being
    // reviewed, and the fix is a generation run rather than anything here.
    if (!tail?.date || tail.date <= date) {
      return json({
        error: 'no queued rounds and nothing scheduled past this date to take one from',
      }, 409);
    }
    unscheduled = tail.date;
    const { results } = await env.ANSWERS.prepare(TAIL_ROUNDS).bind(unscheduled).all();
    replacement = results[0];
    writes.push(
      env.ANSWERS
        .prepare(`UPDATE rounds SET status = 'queued'
                   WHERE image IN (SELECT image FROM round_days WHERE date = ?)`)
        .bind(unscheduled),
      env.ANSWERS.prepare('DELETE FROM round_days WHERE date = ?').bind(unscheduled),
    );
  }

  // A round with no object behind it is a black pane, and a schedule is the one
  // place that failure is invisible until a player hits it -- Pages answers a
  // path it holds no file for with the site's own HTML and a 200. Checked here
  // because this is the only path that schedules a round nobody reviewed.
  // Skipped where CLIPS is unbound, which smoke.sh reports on its own terms.
  if (env.CLIPS && !(await env.CLIPS.head(replacement.image))) {
    return json({
      error: `${replacement.image} has no media in the bucket, so it would play as a black pane`,
    }, 409);
  }

  // One transaction. A half-applied swap is the worst of the three outcomes:
  // it leaves the day four rounds long, which nothing downstream expects.
  //
  // UPDATE rather than a delete and an insert, because round_days is unique on
  // image -- in place there is never a moment where both rounds hold the slot.
  await env.ANSWERS.batch([
    ...writes,
    env.ANSWERS.prepare("UPDATE rounds SET status = 'rejected' WHERE image = ?").bind(image),
    env.ANSWERS
      .prepare('UPDATE round_days SET image = ? WHERE date = ? AND position = ?')
      .bind(replacement.image, date, slot.position),
    env.ANSWERS
      .prepare("UPDATE rounds SET status = 'scheduled' WHERE image = ?")
      .bind(replacement.image),
  ]);

  // `unscheduled` is reported rather than swallowed: a rejection that silently
  // shortened the horizon by a day reads as free, and the next thing anybody
  // asks is why the schedule ends earlier than they remember.
  return json({
    date,
    position: slot.position,
    rejected: image,
    replacement: replacement.image,
    unscheduled_day: unscheduled,
  }, 200, { 'cache-control': 'no-store' });
}
