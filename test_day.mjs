// Cover /api/day: which rounds a date hands out, and which dates it refuses.
//
// Two things here are load-bearing in a way that fails quietly. The order rounds
// come back in *is* the easy-to-hard ramp -- the page no longer sorts, so a
// handler that dropped the ORDER BY would produce games in an arbitrary order and
// nothing would error. And refusing an unopened date is the entire protection on
// a schedule the browser can no longer derive for itself; while the draw was a
// seeded shuffle there was nothing to leak, so this guard has no predecessor and
// no second line behind it.
//
// Against the real schema.sql over node:sqlite, so the queries are the ones that
// will run and the primary keys are the ones that will be enforced.
import assert from 'node:assert/strict';
import { readFileSync } from 'node:fs';

import { d1 } from './_d1.mjs';
import { onRequestGet } from './functions/api/day.js';

const env = { ANSWERS: d1(readFileSync('schema.sql', 'utf8')) };

// A date whose window is long shut, one in the future, and the boundary between
// them. Fixed dates rather than offsets from now, because the play window is the
// thing under test.
const PAST = ['2026-08-01', '2026-08-02', '2026-08-03'];
const FUTURE = '2099-06-01';

let n = 0;
const seed = (date, images) => {
  for (const [i, image] of images.entries()) {
    env.ANSWERS.db
      .prepare(`INSERT INTO rounds
                  (image, median_km, mean_cos, batch, slug, source_ts_sec,
                   clip_ts_sec, radius_m)
                VALUES (?, ?, 0.07, 'test', 'slug', 20, 20, 60)`)
      .run(image, (i + 1) * 10 + n++);
    env.ANSWERS.db
      .prepare('INSERT INTO round_days (date, position, image) VALUES (?, ?, ?)')
      .run(date, i + 1, image);
  }
};

const round = (date, i) => `clips/${date.replaceAll('-', '')}_${i}-0${i}0000.mp4`;
for (const date of [...PAST, FUTURE]) {
  seed(date, [1, 2, 3, 4, 5].map(i => round(date, i)));
}

const get = query => onRequestGet({
  request: new Request(`https://guessr.dana.lol/api/day?${query}`),
  env,
});
const body = async res => [res.status, await res.json()];

// The ordinary case: a date that has finished playing still reads, because a
// player looking at yesterday's board needs the rounds it was made of.
{
  const [status, json] = await body(await get(`date=${PAST[0]}`));
  assert.equal(status, 200);
  assert.equal(json.date, PAST[0]);
  assert.deepEqual(json.rounds.map(r => r.image), [1, 2, 3, 4, 5].map(i => round(PAST[0], i)));
}

// By position, not by whatever order the rows were written in. Seeded backwards
// so an accidental insertion-order read comes out reversed and is caught.
{
  const date = '2026-08-04';
  const images = [5, 4, 3, 2, 1].map(i => round(date, i));
  for (const [i, image] of images.entries()) {
    env.ANSWERS.db
      .prepare(`INSERT INTO rounds
                  (image, median_km, mean_cos, batch, slug, source_ts_sec,
                   clip_ts_sec, radius_m)
                VALUES (?, 5, 0.07, 'test', 'slug', 20, 20, 60)`)
      .run(image);
    env.ANSWERS.db
      .prepare('INSERT INTO round_days (date, position, image) VALUES (?, ?, ?)')
      .run(date, 5 - i, image);
  }
  const [, json] = await body(await get(`date=${date}`));
  assert.deepEqual(json.rounds.map(r => r.image), [1, 2, 3, 4, 5].map(i => round(date, i)));
}

// THE ONE THAT MATTERS. A date nobody can play yet must not be readable, or the
// schedule for the next two months is a GET away and every future daily is
// spoiled. There is no other guard on it.
{
  const [status, json] = await body(await get(`date=${FUTURE}`));
  assert.equal(status, 403, 'a future date was readable');
  assert.match(json.error, /not opened/);
}

// And nothing leaks in the shape of the refusal either: the 403 body must not
// carry the rounds it declined to serve.
{
  const [, json] = await body(await get(`date=${FUTURE}`));
  assert.equal(json.rounds, undefined);
}

// A round is served without its answer. The two live in different tables
// precisely so this endpoint cannot leak one, and this is what pins it -- a
// SELECT * would sail through every other assertion here.
{
  const [, json] = await body(await get(`date=${PAST[0]}`));
  for (const r of json.rounds) {
    assert.deepEqual(Object.keys(r), ['image'],
      `a round carried more than its name: ${JSON.stringify(r)}`);
  }
}

// A date inside the window with nothing scheduled is a 404, distinct from the
// 403 above: one means the generator has not reached that far ahead, the other
// means the date has not arrived. Different fixes, so different codes.
{
  const [status] = await body(await get('date=2020-01-01'));
  assert.equal(status, 404, 'an unscheduled past date should be 404, not 403');
}

// A malformed date never reaches the database.
for (const bad of ['', 'date=', 'date=2026-8-1', 'date=yesterday', 'date=2026-08-01T00:00']) {
  const [status] = await body(await get(bad));
  assert.equal(status, 400, `"${bad}" was not refused`);
}

// Practice draws only from dates that have finished. Drawing over the whole pool
// -- which is what it used to do -- would hand out a date nobody has played yet,
// which is a spoiler rather than practice.
{
  const scheduled = new Set(PAST.flatMap(d => [1, 2, 3, 4, 5].map(i => round(d, i))));
  const future = new Set([1, 2, 3, 4, 5].map(i => round(FUTURE, i)));
  // Repeatedly, because the draw is random: one pass could miss a leak by luck.
  for (let i = 0; i < 25; i++) {
    const [status, json] = await body(await get('practice'));
    assert.equal(status, 200);
    assert.ok(json.rounds.length > 0 && json.rounds.length <= 5);
    for (const r of json.rounds) {
      assert.ok(!future.has(r.image), `practice served an unplayed future round: ${r.image}`);
      assert.ok(scheduled.has(r.image) || r.image.startsWith('clips/20260804'),
        `practice served a round nothing scheduled: ${r.image}`);
    }
  }
}

// Practice against a database where nothing has closed yet says so, rather than
// handing back an empty game the page would render as a zero-round daily.
{
  const empty = { ANSWERS: d1(readFileSync('schema.sql', 'utf8')) };
  const res = await onRequestGet({
    request: new Request('https://guessr.dana.lol/api/day?practice'),
    env: empty,
  });
  assert.equal(res.status, 404);
}

// A served day is cacheable and a practice draw is not -- one is immutable once
// its date opens, the other is meant to differ every time it is asked.
{
  const day = await get(`date=${PAST[0]}`);
  assert.match(day.headers.get('cache-control'), /max-age=\d\d+/);
  const practice = await get('practice');
  assert.equal(practice.headers.get('cache-control'), 'no-store');
}

console.log('ok: a date serves its five in ramp order, and only its names');
console.log('ok: a date nobody can play yet is refused, and leaks nothing');
console.log('ok: unscheduled, malformed and future dates are told apart');
console.log('ok: practice draws only from days that have finished');
