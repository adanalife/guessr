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
// A date that closed before the daily board's, for paging back to. Fixed rather
// than derived, so it can never collide with the moving dates around it.
const earlier = '2020-01-01';
// Up to two days a month the last closed date belongs to the month before, and
// the daily board's plays are then absent from the monthly drilldown.
const bothBoards = day.startsWith(month);

seedAnswers(db, ['a.mp4', 'b.mp4', 'c.mp4', 'd.mp4']);

// Schedule the closed day's rounds so the drilldown can number them. Today's
// play is deliberately left unscheduled, covering the play-without-a-schedule
// row: position null, row intact. round_days references rounds, so the
// scheduled pair need pool rows first; the values are arbitrary.
const round = db.prepare(`INSERT INTO rounds
  (image, median_km, mean_cos, batch, slug, source_ts_sec, clip_ts_sec, radius_m)
  VALUES (?, 1.0, 0.1, 'test', 'slug', 0, 0, 100)`);
round.run('a.mp4');
round.run('b.mp4');
round.run('d.mp4');
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
// An older closed date, where the standings are a different shape entirely --
// p2 alone, so resolving rank 1 against it cannot accidentally land on p1.
schedule.run(earlier, 1, 'd.mp4');
play.run(earlier, 'p2', 'd.mp4', 5.5, 3300, 'Winding Valley', 40.0, -111.0);

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
    { date: day, position: 1, km: 1.2, points: 4800, guess_lat: 34.1, guess_lng: -118.2 },
    { date: day, position: 2, km: 250.0, points: 900, guess_lat: 36.0, guess_lng: -120.0 },
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
// points but WITHOUT its pin -- and the closed day's pins survive alongside it,
// so the guard is the date test and not a blanket strip.
{
  const [status, body] = await get('?board=monthly&rank=1');
  assert.equal(status, 200);
  assert.equal(body.name, 'Amber Basin');

  const openRow = body.rows.find(r => r.date === today);
  assert.deepEqual(openRow,
    { date: today, position: null, km: 3.3, points: 4500, guess_lat: null, guess_lng: null },
    'the open date leaked its pin, kept a schedule position it has none of, '
    + 'or lost its score');

  const closedRows = body.rows.filter(r => r.date === day);
  assert.equal(closedRows.length, bothBoards ? 2 : 0);
  for (const r of closedRows) {
    assert.ok(r.guess_lat !== null && r.guess_lng !== null,
      'a closed date lost its pin to the open-date guard');
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

// Paging back: the rank resolves against the requested date's standings, not
// today's. Getting this wrong is the quiet failure -- rank 1 of the newest
// board is p1, so a drilldown ignoring the date answers with a real player's
// real plays under the wrong day's heading.
assert.deepEqual(await get(`?board=daily&rank=1&date=${earlier}`), [200, {
  board: 'daily', period: earlier, rank: 1, name: 'Winding Valley',
  rows: [{
    date: earlier, position: 1, km: 5.5, points: 3300,
    guess_lat: 40.0, guess_lng: -111.0,
  }],
}]);

// The date is closed, so its pins are served -- the withholding CASE binds the
// last closed date and a requested date is never past it.
assert.deepEqual(await get(`?board=daily&rank=2&date=${earlier}`),
  [404, { error: 'no player at that rank' }],
  'a rank past that date\'s board was not a 404');

// The same refusals the board endpoint makes, because the two resolve the same
// span: an open or future date, a malformed one, and a date on the monthly
// board.
for (const [search, error] of [
  [`?board=daily&rank=1&date=${today}`, 'date has not closed yet'],
  ['?board=daily&rank=1&date=9999-01-01', 'date has not closed yet'],
  ['?board=daily&rank=1&date=2026-2-3', 'date must be YYYY-MM-DD'],
  ['?board=daily&rank=1&date=2026-02-31', 'date must be YYYY-MM-DD'],
  [`?board=monthly&rank=1&date=${earlier}`, 'date applies to the daily board only'],
]) {
  assert.deepEqual(await get(search), [400, { error }], `"${search}" was accepted`);
}

// A dated drilldown is as immutable as the board it came from, and cached to
// match rather than at the live board's minute.
{
  const res = await onRequestGet({
    request: { url: `https://guessr.dana.lol/api/guesses?board=daily&rank=1&date=${earlier}` },
    env,
  });
  assert.equal(res.headers.get('cache-control'), 'public, max-age=3600');
}

console.log('ok: a rank resolves through the board ordering to that row\'s plays');
console.log('ok: an open date answers with score and distance but never its pin');
console.log('ok: a rank the board does not reach is a 404, not a 400 or an empty 200');
console.log('ok: bad boards and bad ranks are refused');
console.log('ok: a dated drilldown resolves its rank against that date\'s board');
console.log('ok: an unclosed, malformed or monthly date is refused here too');
