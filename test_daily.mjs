// Checks the date arithmetic and the window a day is open for. Run with
// `node test_daily.mjs` (or `task test`).
//
// This is the module the page and functions/api/{day,score}.js all import, so a
// rule that reads differently on the two sides means the server refuses plays
// the page legitimately handed out, and says nothing about why.
//
// *Which rounds* a date plays is not tested here any more -- it is a row set in
// D1 rather than a seeded shuffle, so the properties that used to live in this
// file (a day draws the same five every time, no round twice in a game, the draw
// does not depend on the order the pool was written in) are now properties of
// make_rounds.py's schedule(). test_schedule.py is where they went.
import assert from 'node:assert';
import {
  dailyState, dateForDay, dayFromDate, dayNumber,
  effectiveDay, isOpen, lastClosedDate, monthOf, playWindow,
} from './web/daily.js';

// Consecutive calendar days are consecutive day numbers, including across a
// US spring-forward boundary (2026-03-08) where the local day is 23 hours.
assert.strictEqual(
  dayNumber(new Date(2027, 2, 9, 12)) - dayNumber(new Date(2027, 2, 7, 12)), 2,
  'DST boundary skipped or repeated a day number',
);
// The epoch itself is day 1.
assert.strictEqual(dayNumber(new Date(2026, 6, 31)), 1, 'epoch should be day 1');
// Time of day must not matter -- only the calendar date.
assert.strictEqual(dayNumber(new Date(2026, 6, 31, 23, 59)), dayNumber(new Date(2026, 6, 31, 0, 1)));

// dateForDay is the key a play is recorded under, so a day that maps to the
// wrong date files a score against the wrong board. It has to invert dayNumber
// exactly, including across both DST boundaries -- adding 86400000 ms per day
// lands on 23:00 of the previous date every autumn, which formats a day early.
assert.strictEqual(dateForDay(1), '2026-07-31', 'the epoch is not day 1');
assert.strictEqual(dateForDay(2), '2026-08-01');
// Month, year and leap-day rollovers, all of which the Date constructor's
// overflow handling is doing rather than any arithmetic here.
assert.strictEqual(dateForDay(154), '2026-12-31');
assert.strictEqual(dateForDay(155), '2027-01-01');
assert.strictEqual(dateForDay(579), '2028-02-29');
// Zero-padded, since the server matches YYYY-MM-DD literally.
assert.ok(/^\d{4}-\d{2}-\d{2}$/.test(dateForDay(3)), `unpadded: ${dateForDay(3)}`);
// The round trip, over two years of days including both US DST switches. This
// is the property the server leans on: it turns a posted date back into a day
// number to redraw that date's five, so a date the page could produce and the
// server reads differently would reject a legitimate play.
for (let day = 1; day <= 730; day++) {
  assert.strictEqual(dayFromDate(dateForDay(day)), day,
    `day ${day} round-tripped through ${dateForDay(day)}`);
  const [y, m, d] = dateForDay(day).split('-').map(Number);
  assert.strictEqual(dayNumber(new Date(y, m - 1, d, 12)), day,
    `day ${day} did not read back from its own date`);
}

// When a date is open. Everyone gets until their own midnight, so a date runs
// from midnight in UTC+14 (10:00 UTC the day before) to midnight in UTC-12
// (12:00 UTC the day after). Both edges matter for different reasons: the close
// is what lets a board be final, and the open is the only thing stopping a
// script from playing next week today, the draw being public and deterministic.
const utc = s => new Date(`${s}Z`);
const w = playWindow('2026-08-05');
assert.strictEqual(new Date(w.opens).toISOString(), '2026-08-04T10:00:00.000Z');
assert.strictEqual(new Date(w.closes).toISOString(), '2026-08-06T12:00:00.000Z');

assert.equal(isOpen('2026-08-05', utc('2026-08-04T09:59:59')), false, 'opened early');
assert.equal(isOpen('2026-08-05', utc('2026-08-04T10:00:00')), true, 'the open edge is inclusive');
assert.equal(isOpen('2026-08-05', utc('2026-08-05T12:00:00')), true);
assert.equal(isOpen('2026-08-05', utc('2026-08-06T11:59:59')), true);
assert.equal(isOpen('2026-08-05', utc('2026-08-06T12:00:00')), false, 'the close edge is exclusive');
assert.equal(isOpen('2026-08-05', utc('2026-08-12T00:00:00')), false, 'a week later was still open');

// Month and year ends are the case a naive day±1 gets wrong, and Date.UTC's
// overflow handling is what covers them.
assert.strictEqual(new Date(playWindow('2026-09-01').opens).toISOString(),
  '2026-08-31T10:00:00.000Z');
assert.strictEqual(new Date(playWindow('2026-12-31').closes).toISOString(),
  '2027-01-01T12:00:00.000Z');
assert.strictEqual(new Date(playWindow('2028-03-01').opens).toISOString(),
  '2028-02-29T10:00:00.000Z', 'a leap day was skipped');

// Up to three dates are open at once -- which is why the overlay has to choose
// which one it renders rather than assuming there is only ever a "today".
const at11 = utc('2026-08-05T11:00:00');
assert.deepStrictEqual(
  ['2026-08-04', '2026-08-05', '2026-08-06'].map(d => isOpen(d, at11)),
  [true, true, true],
  'three dates should overlap at 11:00 UTC',
);
// And never four.
assert.equal(isOpen('2026-08-07', at11), false);
assert.equal(isOpen('2026-08-03', at11), false);

// Every date is open for exactly 50 hours, whatever the month boundary.
for (const date of ['2026-08-05', '2026-09-01', '2026-12-31', '2028-02-29', '2027-01-01']) {
  const { opens, closes } = playWindow(date);
  assert.strictEqual(closes - opens, 50 * 3600 * 1000, `${date} was not open for 50 hours`);
}

// Which board the overlay shows: the most recent date that can no longer
// change. A board that reorders while it is on screen is worse than a stale one.
assert.strictEqual(lastClosedDate(utc('2026-08-06T12:00:00')), '2026-08-05',
  'a date should be closed the instant its window ends');
assert.strictEqual(lastClosedDate(utc('2026-08-06T11:59:59')), '2026-08-04',
  'a date still open was shown as closed');
// Month and year boundaries, where an off-by-one would show a board from the
// wrong month entirely.
assert.strictEqual(lastClosedDate(utc('2026-09-01T12:00:00')), '2026-08-31');
assert.strictEqual(lastClosedDate(utc('2027-01-01T12:00:00')), '2026-12-31');
assert.strictEqual(lastClosedDate(utc('2028-03-01T12:00:00')), '2028-02-29');

// The property that makes it correct, checked rather than assumed: whatever the
// instant, the date it names is closed and the day after it is not.
for (let h = 0; h < 24 * 14; h++) {
  const now = new Date(Date.UTC(2026, 7, 1) + h * 3600 * 1000);
  const closed = lastClosedDate(now);
  assert.equal(isOpen(closed, now), false, `${closed} was still open at ${now.toISOString()}`);
  const next = dateForDay(dayFromDate(closed) + 1);
  assert.equal(isOpen(next, now), true,
    `${next} should still be open at ${now.toISOString()}, so ${closed} is not the latest closed`);
}

// The monthly board is a running total over the current month, today included --
// no closing rule, because a sum has nothing to settle.
assert.strictEqual(monthOf(utc('2026-08-01T00:00:00')), '2026-08');
assert.strictEqual(monthOf(utc('2026-08-31T23:59:59')), '2026-08');
assert.strictEqual(monthOf(utc('2026-09-01T00:00:00')), '2026-09');

// The three readings of a stored record. A same-day record short of the full
// count must resume, not read as finished -- saving progress every round is what
// stops an abandoned run from being replayed with the answers known, and it only
// works if a partial record is told apart from a complete one.
assert.strictEqual(dailyState(null, 5, 5), 'unplayed');
assert.strictEqual(dailyState({ day: 4, results: [1, 2, 3, 4, 5] }, 5, 5), 'unplayed');
assert.strictEqual(dailyState({ day: 5, results: [] }, 5, 5), 'unfinished');
assert.strictEqual(dailyState({ day: 5, results: [1, 2] }, 5, 5), 'unfinished');
assert.strictEqual(dailyState({ day: 5, results: [1, 2, 3, 4] }, 5, 5), 'unfinished');
assert.strictEqual(dailyState({ day: 5, results: [1, 2, 3, 4, 5] }, 5, 5), 'finished');
// A record longer than the current round count is still finished, so shrinking
// ROUNDS_PER_GAME cannot reopen a day someone already played out.
assert.strictEqual(dailyState({ day: 5, results: [1, 2, 3, 4, 5, 6] }, 5, 5), 'finished');

// A clock that moves backwards must not re-open a played-out day. The record
// carries the highest day reached, so the game stays on it until the calendar
// genuinely catches up.
const flew = { day: 12, results: [1, 2, 3, 4, 5], total: 5 };
assert.strictEqual(effectiveDay(flew, new Date(2026, 7, 9)), 12, 'a backwards clock re-opened a day');
assert.strictEqual(dailyState(flew, effectiveDay(flew, new Date(2026, 7, 9)), 5), 'finished');
// Tomorrow is still tomorrow.
assert.strictEqual(effectiveDay(flew, new Date(2026, 7, 12)), 13);
assert.strictEqual(dailyState(flew, effectiveDay(flew, new Date(2026, 7, 12)), 5), 'unplayed');
// And a first-ever visit has no record to clamp to.
assert.strictEqual(effectiveDay(null, new Date(2026, 7, 1)), dayNumber(new Date(2026, 7, 1)));

console.log('ok: a partial day resumes, a played-out day stays played out');
console.log('ok: the day number only moves forwards, whatever the clock does');
console.log('ok: every day number maps to the calendar date it came from');
console.log('ok: a date is open for 50 hours, and three overlap at once');
console.log("ok: the overlay board is the latest date that can no longer change");
