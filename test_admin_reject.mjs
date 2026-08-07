// Cover POST /admin/day: throwing a round out of an upcoming day, and where its
// replacement comes from.
//
// Two things carry the weight here. The first is the gate, for a harder reason
// than the read next door -- this is a write, so a tier that answers it can
// reorder what players get, and every way of not knowing which tier this is has
// to land on "no". The second is that a rejection is never free: with no queued
// surplus it is paid for out of the schedule's tail, and the tests below pin
// both that it is paid and that the payment is reported rather than silent.
//
// Against the real migrations over node:sqlite, so the constraint that makes the
// swap safe -- round_days unique on image -- is the real one.
import assert from 'node:assert/strict';

import { d1, schema } from './_d1.mjs';
import { onRequestPost } from './functions/admin/day.js';

const assets = tier => ({
  async fetch() {
    if (tier === undefined) return new Response('nope', { status: 404 });
    if (tier === 'broken') return new Response('<html>', { status: 200 });
    return new Response(JSON.stringify({ label: 'test', tier }));
  },
});

// Far enough out that these never open, whenever the suite runs. The frozen-date
// cases below use real past dates for the same reason.
const DAY1 = '2099-06-01';
const DAY2 = '2099-06-02';
const DAY3 = '2099-06-03';
const OPENED = '2020-01-02';

const img = (date, i) => `clips/${date.replaceAll('-', '')}_${i}-0${i}0000.mp4`;

function seeded(dates = [DAY1, DAY2, DAY3]) {
  const answers = d1(schema());
  const round = (image, status) => answers.db
    .prepare(`INSERT INTO rounds
                (image, median_km, mean_cos, batch, status, slug, source_ts_sec,
                 clip_ts_sec, radius_m)
              VALUES (?, 12.5, 0.07, 'test', ?, 'slug', 20.5, 20.5, 61.2)`)
    .run(image, status);
  for (const date of dates) {
    for (let i = 1; i <= 5; i++) {
      round(img(date, i), 'scheduled');
      answers.db
        .prepare('INSERT INTO round_days (date, position, image) VALUES (?, ?, ?)')
        .run(date, i, img(date, i));
    }
  }
  answers.queue = image => round(image, 'queued');
  return answers;
}

// A bucket that has everything, which is the ordinary case; the one that has
// nothing is built inline where it is tested.
const CLIPS = { head: async () => ({ size: 1 }) };

// No default for `tier`: `undefined` is one of the cases that has to refuse (a
// version.json that 404s), and a default parameter would quietly turn it into
// the one tier that does not.
const reject = (env, body, tier) => onRequestPost({
  request: new Request('https://stage.guessr.dana.lol/admin/day', {
    method: 'POST',
    body: typeof body === 'string' ? body : JSON.stringify(body),
  }),
  env: { CLIPS, ASSETS: assets(tier), ...env },
});
// Staging is the ordinary case; only the gate tests above name another tier.
const onStaging = (env, body) => reject(env, body, 'staging');
const body = async res => [res.status, await res.json()];

const scheduleOf = (answers, date) => answers.db
  .prepare('SELECT position, image FROM round_days WHERE date = ? ORDER BY position')
  .all(date);
const statusOf = (answers, image) => answers.db
  .prepare('SELECT status FROM rounds WHERE image = ?').get(image).status;

// THE ONE THAT MATTERS. A write honoured on a deployment this code cannot name
// is strictly worse than a read honoured there: it does not leak tomorrow's
// five, it changes them.
{
  const answers = seeded();
  const [status] = await body(await reject({ ANSWERS: answers }, { date: DAY1, image: img(DAY1, 1) }, 'broken'));
  assert.equal(status, 403, 'an unnameable tier accepted a rejection');
  assert.equal(scheduleOf(answers, DAY1)[0].image, img(DAY1, 1), 'a refused write changed the schedule');
}

// And every way of not knowing, exactly as the read is tested -- including no
// ASSETS binding at all, which is the case a stubbed test is most likely to let
// through.
for (const tier of [undefined, 'broken', 'PRODUCTION', 'prod', '', null]) {
  const answers = seeded();
  const [status] = await body(await reject({ ANSWERS: answers }, { date: DAY1, image: img(DAY1, 1) }, tier));
  assert.equal(status, 403, `an unknown tier (${JSON.stringify(tier)}) was allowed to write`);
  assert.equal(scheduleOf(answers, DAY1)[0].image, img(DAY1, 1));
}
{
  const answers = seeded();
  const res = await onRequestPost({
    request: new Request('https://guessr.dana.lol/admin/day', {
      method: 'POST', body: JSON.stringify({ date: DAY1, image: img(DAY1, 1) }),
    }),
    env: { ANSWERS: answers, CLIPS },   // no ASSETS binding
  });
  assert.equal(res.status, 403, 'a missing ASSETS binding read as a known tier');
}

// A body that is not the two strings this needs.
for (const bad of ['not json', {}, { date: DAY1 }, { image: img(DAY1, 1) },
  { date: '2099-6-1', image: img(DAY1, 1) }, { date: DAY1, image: 42 }]) {
  const [status] = await body(await onStaging({ ANSWERS: seeded() }, bad));
  assert.equal(status, 400, `${JSON.stringify(bad)} was not refused`);
}

// Frozen from the moment a date opens: a player halfway through a game cannot
// have a round swapped underneath them, and a finished day is the record of what
// was played. Both are "has opened", which is why the guard is not isOpen().
for (const date of [OPENED, '2026-08-01']) {
  const answers = seeded([date]);
  const [status, json] = await body(await onStaging({ ANSWERS: answers }, { date, image: img(date, 2) }));
  assert.equal(status, 409, `${date} was editable`);
  assert.match(json.error, /frozen/);
  assert.equal(statusOf(answers, img(date, 2)), 'scheduled', 'a frozen day was modified anyway');
}

// And production honours it, which is the tier this verb was built for: a wrong
// coordinate caught on staging costs nothing, and the same one caught on
// production is the only place the catch is worth anything.
{
  const answers = seeded();
  answers.queue('clips/spare-000000.mp4');
  const [status, json] = await body(await reject({ ANSWERS: answers }, { date: DAY1, image: img(DAY1, 3) }, 'production'));
  assert.equal(status, 200, 'production refused a rejection');
  assert.equal(scheduleOf(answers, DAY1)[2].image, 'clips/spare-000000.mp4');
  assert.equal(json.replacement, 'clips/spare-000000.mp4');
}

// A round that is not on that day at all.
{
  const answers = seeded();
  const [status] = await body(await onStaging({ ANSWERS: answers }, { date: DAY1, image: img(DAY2, 1) }));
  assert.equal(status, 404);
}

// The cheap path: a generation run left surplus, so the rejection spends that
// and the horizon does not move.
{
  const answers = seeded();
  answers.queue('clips/spare-000000.mp4');
  const [status, json] = await body(await onStaging({ ANSWERS: answers }, { date: DAY1, image: img(DAY1, 3) }));
  assert.equal(status, 200);
  assert.equal(json.replacement, 'clips/spare-000000.mp4');
  assert.equal(json.position, 3, 'the replacement did not take the rejected round\'s slot');
  assert.equal(json.unscheduled_day, null, 'a queued round cost a day of runway');
  assert.equal(statusOf(answers, img(DAY1, 3)), 'rejected');
  assert.equal(statusOf(answers, 'clips/spare-000000.mp4'), 'scheduled');
  assert.deepEqual(scheduleOf(answers, DAY1).map(r => r.position), [1, 2, 3, 4, 5],
    'the day did not come out five rounds long');
  assert.equal(scheduleOf(answers, DAY1)[2].image, 'clips/spare-000000.mp4');
  assert.equal(scheduleOf(answers, DAY3).length, 5, 'the tail was touched despite surplus');
}

// The paid path, which is the one that actually fires today: no surplus, so the
// furthest-out day is given up whole and its rounds go back to the pool. Four of
// them survive to be spent on the next rejection, which is the point of
// requeueing rather than deleting.
{
  const answers = seeded();
  const [status, json] = await body(await onStaging({ ANSWERS: answers }, { date: DAY1, image: img(DAY1, 1) }));
  assert.equal(status, 200);
  assert.equal(json.unscheduled_day, DAY3, 'the horizon shrank without saying so');
  assert.equal(json.replacement, img(DAY3, 1));
  assert.equal(scheduleOf(answers, DAY3).length, 0, 'a four-round day was left behind');
  assert.equal(scheduleOf(answers, DAY1).length, 5);
  assert.equal(scheduleOf(answers, DAY1)[0].image, img(DAY3, 1));
  assert.equal(statusOf(answers, img(DAY1, 1)), 'rejected');
  assert.equal(statusOf(answers, img(DAY3, 1)), 'scheduled');
  for (let i = 2; i <= 5; i++) {
    assert.equal(statusOf(answers, img(DAY3, i)), 'queued',
      'a round from the dropped day was stranded rather than requeued');
  }
  // And the next rejection is free, because the one before it paid.
  const [, second] = await body(await onStaging({ ANSWERS: answers }, { date: DAY1, image: img(DAY1, 2) }));
  assert.equal(second.unscheduled_day, null, 'the requeued rounds were not reachable');
}

// A rejected round is not a queued one. This is the whole reason `status` exists
// rather than inferring availability from absence from the schedule: without it
// the round just thrown out is the most obvious candidate to put straight back.
{
  const answers = seeded([DAY1, DAY2]);
  await onStaging({ ANSWERS: answers }, { date: DAY1, image: img(DAY1, 1) });
  assert.equal(statusOf(answers, img(DAY1, 1)), 'rejected');
  const back = answers.db
    .prepare("SELECT count(*) AS n FROM round_days WHERE image = ?").get(img(DAY1, 1)).n;
  assert.equal(back, 0, 'the rejected round was rescheduled');
  const [, json] = await body(await onStaging({ ANSWERS: answers }, { date: DAY1, image: img(DAY1, 2) }));
  assert.notEqual(json.replacement, img(DAY1, 1), 'a rejected round came back as a replacement');
}

// Nothing further out to borrow from, which is the end of the runway. Refusing
// beats emptying the day being reviewed.
{
  const answers = seeded([DAY1]);
  const [status, json] = await body(await onStaging({ ANSWERS: answers }, { date: DAY1, image: img(DAY1, 1) }));
  assert.equal(status, 409);
  assert.match(json.error, /no queued rounds/);
  assert.equal(scheduleOf(answers, DAY1).length, 5, 'the only day was raided for its own replacement');
  assert.equal(statusOf(answers, img(DAY1, 1)), 'scheduled', 'a refused rejection still marked the round');
}

// A replacement with no object behind it plays as a black pane, and Pages
// answers a path it holds no file for with the site's HTML at 200 -- so nothing
// downstream would notice. Refused, and refused before anything is written.
{
  const answers = seeded();
  const res = await onRequestPost({
    request: new Request('https://stage.guessr.dana.lol/admin/day', {
      method: 'POST', body: JSON.stringify({ date: DAY1, image: img(DAY1, 1) }),
    }),
    env: { ANSWERS: answers, ASSETS: assets('staging'), CLIPS: { head: async () => null } },
  });
  const [status, json] = await body(res);
  assert.equal(status, 409);
  assert.match(json.error, /black pane/);
  assert.equal(scheduleOf(answers, DAY1)[0].image, img(DAY1, 1), 'a refused swap still happened');
  assert.equal(scheduleOf(answers, DAY3).length, 5, 'a refused swap still dropped the tail day');
  assert.equal(statusOf(answers, img(DAY1, 1)), 'scheduled');
}

console.log('ok: every way of not knowing the tier refuses the write');
console.log('ok: an opened or finished day is frozen');
console.log('ok: queued surplus is spent first, and costs no runway');
console.log('ok: with no surplus the furthest-out day is given up whole and reported');
console.log('ok: a rejected round never comes back as a replacement');
console.log('ok: a replacement with no media is refused before anything is written');
