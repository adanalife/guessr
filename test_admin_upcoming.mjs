// Cover /admin/upcoming: which dates count as upcoming, and in what order the
// rounds come back.
//
// The date boundary is the thing worth a test. A guessr date stays playable
// until noon UTC the day after it, so the obvious SQL bound -- `date >=
// date('now')` -- drops a date players are mid-game on for twelve hours every
// day, and drops exactly the date most worth looking at. The same off-by-a-
// window is written down against `mirror_stage.py`, where it deletes rather than
// hides.
//
// Against the real migrations over node:sqlite, so the joins are the ones that
// will run.
import assert from 'node:assert/strict';

import { lastClosedDate } from './web/daily.js';
import { d1, schema, seedAnswers } from './_d1.mjs';
import { onRequestGet, query } from './functions/admin/upcoming.js';

// The static-asset binding, standing in for whichever workflow deployed this
// copy -- as in test_admin_day.mjs, since it is the same question.
const assets = tier => ({
  async fetch() {
    if (tier === undefined) return new Response('nope', { status: 404 });
    return new Response(JSON.stringify({ label: 'test', tier }));
  },
});

// Dates relative to the boundary the endpoint actually uses, so this does not
// go red on whichever day it is run.
const shift = (date, days) => {
  const d = new Date(`${date}T00:00:00Z`);
  d.setUTCDate(d.getUTCDate() + days);
  return d.toISOString().slice(0, 10);
};
const CLOSED = lastClosedDate();
const OPEN = shift(CLOSED, 1);       // still playable — the one a date('now') bound loses
const SOON = shift(CLOSED, 2);
const OLD = shift(CLOSED, -3);

function seeded() {
  const answers = d1(schema());
  const round = answers.db.prepare(
    `INSERT INTO rounds
       (image, median_km, mean_cos, batch, status, slug, source_ts_sec,
        clip_ts_sec, radius_m)
     VALUES (?, ?, ?, 'test', 'scheduled', 'trip', 20.5, 20.5, 61.2)`);
  const day = answers.db.prepare(
    'INSERT INTO round_days (date, position, image) VALUES (?, ?, ?)');

  // mean_cos deliberately not in date order, so a result that came back in
  // schedule order rather than ranked comes out wrong instead of coincidentally
  // right.
  const rows = [
    [OLD, 1, 'clips/old-010000.mp4', 0.9],
    [OPEN, 1, 'clips/open-020000.mp4', 0.2],
    [OPEN, 2, 'clips/open-030000.mp4', 0.8],
    [SOON, 1, 'clips/soon-040000.mp4', 0.5],
  ];
  seedAnswers(answers.db, rows.map(r => r[2]));
  for (const [date, position, image, meanCos] of rows) {
    round.run(image, 3.1, meanCos);
    day.run(date, position, image);
  }
  return answers;
}

const get = (tier, answers) => onRequestGet({
  request: new Request('https://stage.guessr.dana.lol/admin/upcoming'),
  env: { ANSWERS: answers, ASSETS: assets(tier) },
});

// The gate, the same one every route in this directory carries: the response is
// a fortnight of unplayed rounds, which is the one thing on this surface that is
// a spoiler rather than a record.
for (const tier of [undefined, 'PRODUCTION', 'prod', '', null]) {
  const res = await get(tier, seeded());
  assert.equal(res.status, 403, `an unknown tier (${JSON.stringify(tier)}) read the schedule`);
  assert.equal((await res.json()).rounds, undefined,
    'the refusal carried the rounds it declined');
}

// THE ONE THAT MATTERS. A date that has opened but not closed is upcoming: its
// players are mid-game, and it is the date a reviewer is most likely to be
// asking about. A `date('now')` bound would drop it for twelve hours a day.
{
  const { since, rounds } = await (await get('production', seeded())).json();
  assert.equal(since, CLOSED, 'the boundary was not the last closed date');
  assert.ok(rounds.some(r => r.date === OPEN),
    'a date still open to play was left out of what is upcoming');
  assert.ok(!rounds.some(r => r.date === OLD),
    'a date that closed days ago came back as upcoming');
  // And the SQL says so itself, rather than only the handler that binds it: a
  // date expression creeping back into the WHERE clause is the regression.
  assert.ok(!/date\s*\(\s*'now'/.test(query),
    'the query resolves its own boundary instead of taking the play window');
}

// Ranked by distinctiveness, not by the day it lands on -- the page exists to
// compare rounds across the horizon.
{
  const { rounds } = await (await get('production', seeded())).json();
  assert.deepEqual(rounds.map(r => r.mean_cos), [0.8, 0.5, 0.2],
    'rounds did not come back most distinctive first');
  assert.equal(rounds[2].position, 1, 'the position that flags an opener was dropped');
}

// A scheduled round whose answers push never happened still comes back, with no
// state. Dropping it would hide the failure the day preview exists to catch.
{
  const answers = seeded();
  answers.db.prepare(
    `INSERT INTO rounds
       (image, median_km, mean_cos, batch, status, slug, source_ts_sec,
        clip_ts_sec, radius_m)
     VALUES ('clips/answerless-050000.mp4', 3.1, 0.95, 'test', 'scheduled', 'trip',
             20.5, 20.5, 61.2)`).run();
  answers.db.prepare('INSERT INTO round_days (date, position, image) VALUES (?, 3, ?)')
    .run(SOON, 'clips/answerless-050000.mp4');

  const { rounds } = await (await get('production', answers)).json();
  const orphan = rounds.find(r => r.image === 'clips/answerless-050000.mp4');
  assert.ok(orphan, 'a scheduled round with no answer row was hidden');
  assert.equal(orphan.state, null, 'a round with no answer row invented a state');
}

// An exhausted schedule is an empty list and a boundary to say so against, not
// an error -- the page's loudest message is the one it prints for this.
{
  const answers = d1(schema());
  const { since, rounds } = await (await get('production', answers)).json();
  assert.deepEqual(rounds, []);
  assert.equal(since, CLOSED);
}

console.log('ok: upcoming keeps the open date, ranks by distinctiveness, and shows an answerless round');
