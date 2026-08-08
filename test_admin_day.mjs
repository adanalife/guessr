// Cover /admin/day: who may read a day's answers, and what a day looks like when
// they may.
//
// The gate is the whole test. This endpoint deliberately does the two things
// /api/day exists to refuse -- serve an unopened date, and serve coordinates --
// so behind the login it answers on every tier it recognises, and every way of
// not recognising one has to land on "no". A regression here is silent from the
// outside: the endpoint keeps working, on production too.
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

// `spares` is queued surplus: rounds generated and never given a date. They are
// what a rejection is paid out of first, so a day is only as safe to reject from
// as this number is above zero -- which is why the endpoint reports it.
function seeded(spares = 0) {
  const answers = d1(schema());
  let n = 0;
  const insert = (image, median_km, status, slug) => answers.db
    .prepare(`INSERT INTO rounds
                (image, median_km, mean_cos, batch, status, slug, source_ts_sec,
                 clip_ts_sec, radius_m)
              VALUES (?, ?, 0.07, 'test', ?, ?, 20.5, 20.5, 61.2)`)
    .run(image, median_km, status, slug);
  const seed = (date, withAnswer = true) => {
    for (let i = 1; i <= 5; i++) {
      const image = `clips/${date.replaceAll('-', '')}_${i}-0${i}0000.mp4`;
      // Spelled out rather than left to the column default: a round on a date is
      // 'scheduled', and seeding it 'queued' would make the surplus count come
      // back right for the wrong reason.
      insert(image, (i * 10) + n++, 'scheduled', `20180612_${i}`);
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
  // No answer rows and no date: surplus is a pool question, not a map one, so
  // these are deliberately invisible to the pool the page plots.
  for (let i = 1; i <= spares; i++) {
    insert(`clips/spare-00000${i}.mp4`, i, 'queued', `20180612_spare${i}`);
  }
  return answers;
}

const get = (tier, query, answers = seeded()) => onRequestGet({
  request: new Request(`https://stage.guessr.dana.lol/admin/day?${query}`),
  env: { ANSWERS: answers, ASSETS: assets(tier) },
});
const body = async res => [res.status, await res.json()];

// THE ONE THAT MATTERS. A deployment this code cannot name must not answer, and
// the refusal must carry nothing -- this is the endpoint that joins the answer
// key.
{
  const res = await get('broken', `date=${FUTURE}`);
  const [status, json] = await body(res);
  assert.equal(status, 403, 'an unnameable tier served a future day');
  assert.equal(json.rounds, undefined, 'the refusal carried the rounds it declined');
}

// And every way of not knowing which tier this is has to land there too: no
// version.json, an unparseable one, a tier nobody has heard of -- including the
// right name in the wrong shape, since the match is exact -- and no ASSETS
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
  assert.equal(res.status, 403, 'a missing ASSETS binding read as a known tier');
}

// The tier check runs before the date is parsed, so a refusing tier answers the
// same way whatever it is asked -- there is nothing to learn from which refusal
// comes back.
{
  const [status] = await body(await get('broken', 'date=nonsense'));
  assert.equal(status, 403, 'a refusal distinguished a malformed date from a refusal');
}

// What the tool is for: a date nobody can play yet, in ramp order, with the
// answers attached. Production among them -- its schedule is the one whose
// wrong coordinate reaches players, so it is the tier a review matters most on.
for (const tier of ['production', 'staging', 'preview', 'local']) {
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
  const [, json] = await body(await get('broken', `date=${FUTURE}`));
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

// And how much spare sits behind it, which is the half that says whether that
// horizon holds. Zero is the state worth showing: every round in the database is
// promised to a date, so the next rejection is paid for by giving one back.
{
  const [, json] = await body(await get('staging', `date=${PAST}`));
  assert.equal(json.queued, 0, 'scheduled rounds were counted as spare');
}
{
  const [, json] = await body(await get('staging', `date=${PAST}`, seeded(3)));
  assert.equal(json.queued, 3, 'the queued surplus was miscounted');
  assert.equal(json.pool.length, 10, 'undated spares were plotted on the map');
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

console.log('ok: every way of not knowing the tier refuses');
console.log('ok: a known tier reads an unopened day in ramp order, answers attached');
console.log('ok: a round whose answer was never pushed shows up as such');
console.log('ok: the schedule horizon and the queued surplus behind it come back with the day');
