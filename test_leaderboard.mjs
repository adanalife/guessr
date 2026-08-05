// Cover the board query: who places, in what order, and under which name.
//
// Worth testing because every way it goes wrong is silent. A board with the
// wrong name on it renders perfectly, and the wrong-name case is exactly the one
// nobody can reproduce on demand -- it needs a player who rerolled between two
// plays, which no amount of clicking through `task dev` produces by accident.
//
// It runs the real query against a real SQLite over the real schema.sql, so the
// only thing not exercised here is D1's binding layer.

import assert from 'node:assert/strict';
import { DatabaseSync } from 'node:sqlite';
import { schema } from './_d1.mjs';
import { label, query } from './functions/api/leaderboard.js';
import { ADJECTIVES, NOUNS } from './web/alias.js';

const DAILY = query('= ?');
const MONTHLY = query("LIKE ? || '-%'");

// played_at is a plain string column, so a test can hand-place rows in time
// rather than sleep through a second to separate two of them.
let tick = 0;
const at = () => `2026-08-01 12:00:${String(tick++).padStart(2, '0')}`;

function db(rows) {
  const d = new DatabaseSync(':memory:');
  d.exec(schema());
  const insert = d.prepare(`INSERT INTO plays
    (date, player_id, image, km, points, handle, played_at)
    VALUES (?, ?, ?, ?, ?, ?, ?)`);
  for (const [date, player, image, points, handle, when] of rows) {
    insert.run(date, player, image, 1.0, points, handle, when ?? at());
  }
  return d;
}

const board = (d, sql, period) => d.prepare(sql).all(period, 10)
  .map(r => [r.name, r.points]);

// A player who rerolls mid-day wears the new name, not the alphabetically-last
// one -- which is the whole point, and which both orderings below have to agree
// on or the test is only pinning the sort it happened to get.
for (const [first, second] of [
  ['Winding Valley', 'Amber Basin'],  // renaming down the alphabet
  ['Amber Basin', 'Winding Valley'],  // and up it
]) {
  const d = db([
    ['2026-08-01', 'p1', 'a.jpg', 100, first],
    ['2026-08-01', 'p1', 'b.jpg', 200, second],
  ]);
  assert.deepEqual(board(d, DAILY, '2026-08-01'), [[second, 300]],
    `renaming ${first} -> ${second} did not take`);
}

// The rename reaches back: a name changed today shows on a day that closed
// before it existed. Without this a player can only ever see a new name on a
// board they have not played yet.
{
  const d = db([
    ['2026-07-30', 'p1', 'a.jpg', 100, 'Amber Basin'],
    ['2026-08-01', 'p1', 'b.jpg', 100, 'Winding Valley'],
  ]);
  assert.deepEqual(board(d, DAILY, '2026-07-30'), [['Winding Valley', 100]],
    'a closed day kept the old name');
}

// A nameless play does not blank a name the player still has. This is the
// realistic one: parsePlay drops a forged handle, so a single scripted post
// would otherwise wipe the label off a legitimate player's whole history.
{
  const d = db([
    ['2026-08-01', 'p1', 'a.jpg', 100, 'Amber Basin'],
    ['2026-08-01', 'p1', 'b.jpg', 100, null],
  ]);
  assert.deepEqual(board(d, DAILY, '2026-08-01'), [['Amber Basin', 200]],
    'a nameless play erased a name');
}

// A player with no name anywhere still places; the handler renders the null as
// the placeholder.
{
  const d = db([['2026-08-01', 'p1', 'a.jpg', 100, null]]);
  assert.deepEqual(board(d, DAILY, '2026-08-01'), [[null, 100]]);
}

// Same second, two rounds: insert order decides, so a reroll between two quick
// plays is not a coin flip.
{
  const when = '2026-08-01 12:00:00';
  const d = db([
    ['2026-08-01', 'p1', 'a.jpg', 100, 'Amber Basin', when],
    ['2026-08-01', 'p1', 'b.jpg', 100, 'Winding Valley', when],
  ]);
  assert.deepEqual(board(d, DAILY, '2026-08-01'), [['Winding Valley', 200]],
    'a same-second tie did not fall back to insert order');
}

// The ranking itself, which the name change must not disturb: points sum per
// player across the span, best first, and two players stay two players even
// wearing the same alias.
{
  const d = db([
    ['2026-08-01', 'p1', 'a.jpg', 100, 'Amber Basin'],
    ['2026-08-01', 'p2', 'a.jpg', 400, 'Amber Basin'],
    ['2026-08-01', 'p1', 'b.jpg', 200, 'Amber Basin'],
    ['2026-08-02', 'p1', 'a.jpg', 900, 'Amber Basin'],   // another day, same month
    ['2026-07-31', 'p1', 'a.jpg', 500, 'Amber Basin'],   // another month entirely
  ]);
  assert.deepEqual(board(d, DAILY, '2026-08-01'),
    [['Amber Basin', 400], ['Amber Basin', 300]],
    'the daily board is not one date, best first');
  assert.deepEqual(board(d, MONTHLY, '2026-08'),
    [['Amber Basin', 1200], ['Amber Basin', 400]],
    'the monthly board is not the month summed');
}

// Two players wearing the same alias, which the wordlist makes likely rather
// than exotic. Numbering runs in board order, so the better score takes (1).
assert.deepEqual(
  label(['Amber Basin', 'Winding Valley', 'Amber Basin']),
  ['Amber Basin (1)', 'Winding Valley', 'Amber Basin (2)'],
);

// A board with nothing repeated is left exactly as it came, which is the common
// case and the one a viewer sees every day.
const distinct = ['Amber Basin', 'Winding Valley', 'Lucky Overpass'];
assert.deepEqual(label(distinct), distinct, 'numbered a board with no collision');
assert.deepEqual(label([]), []);
assert.deepEqual(label(['Amber Basin']), ['Amber Basin']);

// Three-way, and two separate collisions on one board -- each set counts on its
// own rather than sharing a running total.
assert.deepEqual(
  label(['Amber Basin', 'Amber Basin', 'Amber Basin']),
  ['Amber Basin (1)', 'Amber Basin (2)', 'Amber Basin (3)'],
);
assert.deepEqual(
  label(['Amber Basin', 'Winding Valley', 'Amber Basin', 'Winding Valley']),
  ['Amber Basin (1)', 'Winding Valley (1)', 'Amber Basin (2)', 'Winding Valley (2)'],
);

// Nameless players are several players, not one. Without this a board renders
// "anonymous" twice with no way to read it as two people.
assert.deepEqual(
  label(['anonymous', 'Amber Basin', 'anonymous']),
  ['anonymous (1)', 'Amber Basin', 'anonymous (2)'],
);

// A numbered name still fits an overlay row. The longest pair the generator can
// make is 20 characters, and a full board of ten of them is the worst case.
const longest = `${[...ADJECTIVES].sort((a, b) => b.length - a.length)[0]} `
  + `${[...NOUNS].sort((a, b) => b.length - a.length)[0]}`;
for (const name of label(Array(10).fill(longest))) {
  assert.ok(name.length <= 25, `"${name}" is too wide for a board row`);
}

// Whether the name subquery seeks an index or scans the table is invisible in
// the results -- both return the same board -- and shows up only as D1
// rows-read, where a continuously-polled board on a few hundred rows is enough
// to pass the free-tier ceiling. So this asserts the plan. Several players over
// several dates, because a planner given one row may reasonably prefer a scan.
{
  const rows = [];
  for (const date of ['2026-08-01', '2026-08-02', '2026-08-03']) {
    for (const p of ['p1', 'p2', 'p3', 'p4']) {
      rows.push([date, p, `${p}-${date}.jpg`, 100, `Name ${p}`]);
    }
  }
  const d = db(rows);
  for (const [name, sql, period] of [
    ['daily', DAILY, '2026-08-01'],
    ['monthly', MONTHLY, '2026-08'],
  ]) {
    const plan = d.prepare(`EXPLAIN QUERY PLAN ${sql}`).all(period, 10)
      .map(r => r.detail).join('\n');
    assert.match(plan, /USING (COVERING )?INDEX plays_by_player_recent/,
      `the ${name} board's name subquery is not using plays_by_player_recent, `
      + `so it scans plays once per row:\n${plan}`);
  }
}

console.log('ok: a reroll renames a player on every board, back through history');
console.log('ok: a nameless play does not cost a player their name');
console.log('ok: the boards still rank by summed points over their own span');
console.log('ok: players sharing an alias are numbered apart on the board');
console.log('ok: both boards seek the name index instead of scanning per row');
