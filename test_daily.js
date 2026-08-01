// Checks the daily-round draw. Run with `node test_daily.js` (or `task test`).
//
// daily.js is a plain script rather than a module, so eval in this scope is how
// the test gets at its functions without adding a module system for one file.
const assert = require('node:assert');
const fs = require('node:fs');

eval(fs.readFileSync(`${__dirname}/web/daily.js`, 'utf8'));

const pool = Array.from({ length: 60 }, (_, i) => ({
  image: `frames/clip_${String(i).padStart(3, '0')}.jpg`,
  median_km: (i * 37) % 250,
}));

// Same day, same rounds -- the property the whole share mechanic rests on.
assert.deepStrictEqual(dailyRounds(pool, 42, 5), dailyRounds(pool, 42, 5));

// Different days draw different rounds, or every day is the same puzzle.
const distinct = new Set(
  Array.from({ length: 30 }, (_, d) => dailyRounds(pool, d + 1, 5).map(r => r.image).join()),
);
assert.ok(distinct.size >= 29, `30 days produced only ${distinct.size} distinct draws`);

// The draw must not depend on the order make_rounds.py wrote the pool in,
// otherwise regenerating rounds.json silently reshuffles today's puzzle.
const shuffled = [...pool].reverse();
assert.deepStrictEqual(dailyRounds(shuffled, 7, 5), dailyRounds(pool, 7, 5));

// No round appears twice in one game.
const picked = dailyRounds(pool, 99, 5).map(r => r.image);
assert.strictEqual(new Set(picked).size, 5, 'a round was drawn twice');
assert.strictEqual(picked.length, 5);

// Consecutive calendar days are consecutive day numbers, including across a
// US spring-forward boundary (2026-03-08) where the local day is 23 hours.
assert.strictEqual(
  dayNumber(new Date(2027, 2, 9, 12)) - dayNumber(new Date(2027, 2, 7, 12)), 2,
  'DST boundary skipped or repeated a day number',
);
// The epoch itself is day 1. Spelled out rather than read from daily.js
// because `const` inside eval does not leak into this scope (function
// declarations do, which is why the rest is reachable).
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
// The round trip, over two years of days including both US DST switches.
for (let day = 1; day <= 730; day++) {
  const [y, m, d] = dateForDay(day).split('-').map(Number);
  assert.strictEqual(dayNumber(new Date(y, m - 1, d, 12)), day,
    `day ${day} round-tripped through ${dateForDay(day)}`);
}

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

// A game ramps easy to hard.
const ramped = rampEasyToHard(dailyRounds(pool, 12, 5));
assert.deepStrictEqual(
  ramped.map(r => r.median_km),
  [...ramped.map(r => r.median_km)].sort((a, b) => a - b),
  'game is not ordered easy to hard',
);

// Ramping must not change *which* rounds are in the game, or the daily set
// stops being the same five for everyone.
const drawn = dailyRounds(pool, 12, 5).map(r => r.image);
assert.deepStrictEqual([...ramped.map(r => r.image)].sort(), [...drawn].sort());

// Ramping is a copy, not an in-place sort of the caller's array.
const original = dailyRounds(pool, 12, 5);
const before = original.map(r => r.image);
rampEasyToHard(original);
assert.deepStrictEqual(original.map(r => r.image), before, 'rampEasyToHard mutated its input');

// The bands are monotonic in median_km and cover the whole range.
assert.strictEqual(difficulty({ median_km: 0 }), 1);
assert.strictEqual(difficulty({ median_km: 31.9 }), 1);
assert.strictEqual(difficulty({ median_km: 32 }), 2);
assert.strictEqual(difficulty({ median_km: 119.9 }), 2);
assert.strictEqual(difficulty({ median_km: 120 }), 3);
assert.strictEqual(difficulty({ median_km: 5000 }), 3);

console.log('ok: daily draw is deterministic, order-independent, and DST-safe');
console.log('ok: games ramp easy to hard without changing the draw');
console.log('ok: a partial day resumes, a played-out day stays played out');
console.log('ok: the day number only moves forwards, whatever the clock does');
console.log('ok: every day number maps to the calendar date it came from');
