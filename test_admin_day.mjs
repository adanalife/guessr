// Cover /admin/day: who may read a day's answers, and what a day looks like when
// they may.
//
// The gate is the whole test. This endpoint deliberately does the two things
// /api/day exists to refuse -- serve an unopened date, and serve coordinates --
// so the only thing between the answer key and the public internet is a tier
// check, and every way of failing that check has to land on "no". A regression
// here is silent from the outside: the endpoint keeps working, on production too.
//
// Against the real migrations over node:sqlite, so the joins are the ones that
// will run.
import assert from 'node:assert/strict';

import { d1, schema } from './_d1.mjs';
import { onRequestGet } from './functions/admin/day.js';

// The static-asset binding, standing in for whichever workflow deployed this
// copy. `undefined` is a version.json that 404s (a local directory nobody
// stamped); `broken` is one that will not parse.
const assets = tier => ({
  async fetch() {
    if (tier === undefined) return new Response('nope', { status: 404 });
    if (tier === 'broken') return new Response('<html>', { status: 200 });
    return new Response(JSON.stringify({ label: 'test', tier }));
  },
});

const PAST = '2026-08-01';
const FUTURE = '2099-06-01';
const LATER = '2099-06-02';

function seeded() {
  const answers = d1(schema());
  let n = 0;
  const seed = (date, withAnswer = true) => {
    for (let i = 1; i <= 5; i++) {
      const image = `clips/${date.replaceAll('-', '')}_${i}-0${i}0000.mp4`;
      answers.db
        .prepare(`INSERT INTO rounds
                    (image, median_km, mean_cos, batch, slug, source_ts_sec,
                     clip_ts_sec, radius_m)
                  VALUES (?, ?, 0.07, 'test', ?, 20.5, 20.5, 61.2)`)
        .run(image, (i * 10) + n++, `20180612_${i}`);
      answers.db
        // Backwards, so a handler that read insertion order instead of position
        // comes out reversed and is caught.
        .prepare('INSERT INTO round_days (date, position, image) VALUES (?, ?, ?)')
        .run(date, 6 - i, image);
      if (withAnswer) {
        answers.db
          .prepare('INSERT INTO answers (image, lat, lng, state, filmed) VALUES (?, ?, ?, ?, ?)')
          .run(image, 41.5 + i, -87.5 - i, 'Indiana', '2018-06-12');
      }
    }
  };
  seed(PAST);
  seed(FUTURE);
  seed(LATER, false);
  return answers;
}

const get = (tier, query) => onRequestGet({
  request: new Request(`https://stage.guessr.dana.lol/admin/day?${query}`),
  env: { ANSWERS: seeded(), ASSETS: assets(tier) },
});
const body = async res => [res.status, await res.json()];

// THE ONE THAT MATTERS. Production must not answer, and the refusal must carry
// nothing -- this is the endpoint that joins the answer key.
{
  const res = await get('production', `date=${FUTURE}`);
  const [status, json] = await body(res);
  assert.equal(status, 403, 'production served a future day');
  assert.equal(json.rounds, undefined, 'the refusal carried the rounds it declined');
}

// And every way of not knowing which tier this is has to land there too: no
// version.json, an unparseable one, a tier nobody has heard of, and no ASSETS
// binding at all.
for (const tier of [undefined, 'broken', 'PRODUCTION', 'prod', '', null]) {
  const [status] = await body(await get(tier, `date=${FUTURE}`));
  assert.equal(status, 403, `an unknown tier (${JSON.stringify(tier)}) was allowed to read`);
}
{
  const res = await onRequestGet({
    request: new Request(`https://guessr.dana.lol/admin/day?date=${FUTURE}`),
    env: { ANSWERS: seeded() },   // no ASSETS binding
  });
  assert.equal(res.status, 403, 'a missing ASSETS binding read as a testing tier');
}

// The tier check runs before the date is parsed, so production answers the same
// way whatever it is asked -- there is nothing to learn from which refusal comes
// back.
{
  const [status] = await body(await get('production', 'date=nonsense'));
  assert.equal(status, 403, 'production distinguished a malformed date from a refusal');
}

// What the tool is for: a date nobody can play yet, in ramp order, with the
// answers attached.
for (const tier of ['staging', 'preview', 'local']) {
  const [status, json] = await body(await get(tier, `date=${FUTURE}`));
  assert.equal(status, 200, `${tier} could not read a future day`);
  assert.equal(json.date, FUTURE);
  assert.equal(json.open, false, 'a 2099 date was reported as open');
  assert.deepEqual(json.rounds.map(r => r.position), [1, 2, 3, 4, 5]);
  for (const r of json.rounds) {
    assert.ok(typeof r.lat === 'number' && typeof r.lng === 'number',
      'a round arrived without its answer');
    assert.ok(r.state && r.filmed && r.slug);
    assert.ok(typeof r.median_km === 'number' && typeof r.radius_m === 'number');
  }
}

// The pool the map draws: every round that has an answer, whatever its status
// and whatever date is being looked at -- a day's five say nothing about the
// shape of the set they came out of. Rounds with no answer row cannot be
// plotted and are not in it.
{
  const [, json] = await body(await get('staging', `date=${FUTURE}`));
  assert.equal(json.pool.length, 10, 'the pool was not every round with an answer');
  for (const p of json.pool) {
    assert.ok(typeof p.lat === 'number' && typeof p.lng === 'number',
      'a pool point arrived without coordinates');
    assert.ok(p.status, 'a pool point arrived without a status to colour it by');
  }
}

// And it is behind the same gate as the answers, because it is the answers:
// coordinates for every round in the database, which is strictly more than the
// day the refusal above is protecting.
{
  const [, json] = await body(await get('production', `date=${FUTURE}`));
  assert.equal(json.pool, undefined, 'the refusal carried the pool coordinates');
}

// A day that has finished reads the same way, which is the browse-the-past half.
{
  const [status, json] = await body(await get('staging', `date=${PAST}`));
  assert.equal(status, 200);
  assert.equal(json.rounds.length, 5);
}

// A round scheduled with no answer row still appears, with the answer missing
// rather than the round. Dropping it would hide the exact failure -- a rounds
// push whose answers push never happened -- that this view is the only place to
// notice before a player does.
{
  const [status, json] = await body(await get('staging', `date=${LATER}`));
  assert.equal(status, 200, 'a day with unpushed answers was not readable');
  assert.equal(json.rounds.length, 5, 'rounds without answers were dropped');
  assert.equal(json.rounds[0].lat, null);
}

// How far the schedule reaches, which is the question the page's header answers.
{
  const [, json] = await body(await get('staging', `date=${PAST}`));
  assert.equal(json.scheduled_through, LATER);
}

// An unscheduled date is a 404 and a malformed one a 400, told apart for the
// same reason /api/day tells them apart: different fixes.
{
  const [status] = await body(await get('staging', 'date=2020-01-01'));
  assert.equal(status, 404);
}
for (const bad of ['', 'date=', 'date=2026-8-1', 'date=tomorrow', 'date=2026-08-01T00:00']) {
  const [status] = await body(await get('staging', bad));
  assert.equal(status, 400, `"${bad}" was not refused`);
}

// Never cached: an unopened day is the one thing here that can still be
// regenerated out from under a review.
{
  const res = await get('staging', `date=${FUTURE}`);
  assert.equal(res.headers.get('cache-control'), 'no-store');
}

console.log('ok: production refuses, and so does every way of not knowing the tier');
console.log('ok: a testing tier reads an unopened day in ramp order, answers attached');
console.log('ok: a round whose answer was never pushed shows up as such');
console.log('ok: the schedule horizon comes back with the day');
