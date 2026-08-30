// Cover the board-row drilldown: which player a rank resolves to, which plays
// come back, and -- the half that matters most -- which coordinates do NOT.
//
// The pin guard is the security property here: the monthly board includes the
// open date, and a strong player's pin on an open round is a public copy of
// roughly where the answer is. Everything else on this endpoint could regress
// visibly; that one regresses as a working response with two extra fields.
//
// Same arrangement as test_leaderboard.mjs: the real handler over the real
// migrations, with only D1's binding layer stubbed.

import assert from 'node:assert/strict';
import { d1, schema, seedAnswers } from './_d1.mjs';
import { onRequestGet } from './functions/api/guesses.js';
import { lastClosedDate, monthOf } from './web/daily.js';

const env = { ANSWERS: d1(schema()) };
const db = env.ANSWERS.db;

// The three dates the endpoint distinguishes: the last closed date (the daily
// board), today (open, in the running month), and a date outside the month
// entirely. Derived rather than fixed, because all three move with the clock.
const day = lastClosedDate();
const month = monthOf();
const today = new Date().toISOString().slice(0, 10);
// Up to two days a month the last closed date belongs to the month before, and
// the daily board's plays are then absent from the monthly drilldown.
const bothBoards = day.startsWith(month);

seedAnswers(db, ['a.mp4', 'b.mp4', 'c.mp4']);

// Schedule the closed day's rounds so the drilldown can number them. Today's
// play is deliberately left unscheduled, covering the play-without-a-schedule
// row: position null, row intact. round_days references rounds, so the
// scheduled pair need pool rows first; the values are arbitrary.
const round = db.prepare(`INSERT INTO rounds
  (image, median_km, mean_cos, batch, slug, source_ts_sec, clip_ts_sec, radius_m)
  VALUES (?, 1.0, 0.1, 'test', 'slug', 0, 0, 100)`);
round.run('a.mp4');
round.run('b.mp4');
const schedule = db.prepare(
  'INSERT INTO round_days (date, position, image) VALUES (?, ?, ?)');
schedule.run(day, 1, 'a.mp4');
schedule.run(day, 2, 'b.mp4');

const play = db.prepare(`INSERT INTO plays
  (date, player_id, image, km, points, handle, guess_lat, guess_lng)
  VALUES (?, ?, ?, ?, ?, ?, ?, ?)`);
play.run(day, 'p1', 'a.mp4', 1.2, 4800, 'Amber Basin', 34.1, -118.2);
play.run(day, 'p1', 'b.mp4', 250.0, 900, 'Amber Basin', 36.0, -120.0);
play.run(day, 'p2', 'a.mp4', 9.0, 4000, 'Winding Valley', 34.5, -118.5);
play.run(today, 'p1', 'c.mp4', 3.3, 4500, 'Amber Basin', 45.0, -122.0);

const get = async search => {
  const request = { url: `https://guessr.dana.lol/api/guesses${search}` };
  const res = await onRequestGet({ request, env });
  return [res.status, await res.json()];
};

// The daily drilldown: rank 1 is p1 (4800+900 beats 4000), its rows are that
// date only, numbered by the schedule, pins included -- the date is closed.
assert.deepEqual(await get('?board=daily&rank=1'), [200, {
  board: 'daily', period: day, rank: 1, name: 'Amber Basin',
  rows: [
    { date: day, position: 1, image: 'a.mp4', km: 1.2, points: 4800, guess_lat: 34.1, guess_lng: -118.2 },
    { date: day, position: 2, image: 'b.mp4', km: 250.0, points: 900, guess_lat: 36.0, guess_lng: -120.0 },
  ],
}]);

// Rank 2 is the other player -- the rank resolves through the same ordering the
// board renders, not to whoever played first.
{
  const [status, body] = await get('?board=daily&rank=2');
  assert.equal(status, 200);
  assert.equal(body.name, 'Winding Valley');
  assert.equal(body.rows.length, 1);
}

// A rank below the board is an answer, not a request error.
assert.deepEqual(await get('?board=daily&rank=3'),
  [404, { error: 'no player at that rank' }]);

// The monthly drilldown carries the open date's play with its distance and
// points but WITHOUT its pin or its clip -- and the closed day's pins and clips
// survive alongside it, so the guard is the date test and not a blanket strip.
{
  const [status, body] = await get('?board=monthly&rank=1');
  assert.equal(status, 200);
  assert.equal(body.name, 'Amber Basin');

  const openRow = body.rows.find(r => r.date === today);
  assert.deepEqual(openRow,
    { date: today, position: null, image: null, km: 3.3, points: 4500,
      guess_lat: null, guess_lng: null },
    'the open date leaked its pin or the clip it was guessed against, kept a '
    + 'schedule position it has none of, or lost its score');

  const closedRows = body.rows.filter(r => r.date === day);
  assert.equal(closedRows.length, bothBoards ? 2 : 0);
  for (const r of closedRows) {
    assert.ok(r.guess_lat !== null && r.guess_lng !== null,
      'a closed date lost its pin to the open-date guard');
    assert.ok(r.image !== null,
      'a closed date lost its clip to the open-date guard');
  }
}

// Anything that is not one of the two boards at a rank the board can hold is
// refused -- a typo'd poller finds out here, not from an empty 200.
for (const search of ['?board=weekly&rank=1', '?board=Daily&rank=1']) {
  assert.deepEqual(await get(search),
    [400, { error: 'board must be daily or monthly' }], `"${search}" was accepted`);
}
for (const rank of ['0', '11', '2.5', 'abc', '']) {
  const [status] = await get(`?board=daily&rank=${rank}`);
  assert.equal(status, 400, `rank "${rank}" was accepted`);
}
assert.equal((await get(''))[0], 400, 'a missing rank was accepted');

console.log('ok: a rank resolves through the board ordering to that row\'s plays');
console.log('ok: an open date answers with score and distance but never its pin or clip');
console.log('ok: a rank the board does not reach is a 404, not a 400 or an empty 200');
console.log('ok: bad boards and bad ranks are refused');
