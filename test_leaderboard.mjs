// Cover the board query: who places, in what order, and under which name.
//
// Worth testing because every way it goes wrong is silent. A board with the
// wrong name on it renders perfectly, and the wrong-name case is exactly the one
// nobody can reproduce on demand -- it needs a player who rerolled between two
// plays, which no amount of clicking through `task dev` produces by accident.
//
// It runs the real query against a real SQLite over the real migrations, so the
// only thing not exercised here is D1's binding layer.

import assert from 'node:assert/strict';
import { DatabaseSync } from 'node:sqlite';
import { d1, schema, seedAnswers } from './_d1.mjs';
import { label, onRequestGet, query } from './functions/api/leaderboard.js';
import { ADJECTIVES, NOUNS } from './web/alias.js';
import { lastClosedDate, monthOf } from './web/daily.js';

const DAILY = query('= ?');
const MONTHLY = query("LIKE ? || '-%'");

// played_at is a plain string column, so a test can hand-place rows in time
// rather than sleep through a second to separate two of them.
let tick = 0;
const at = () => `2026-08-01 12:00:${String(tick++).padStart(2, '0')}`;

function db(rows) {
  const d = new DatabaseSync(':memory:');
  d.exec(schema());
  seedAnswers(d, rows.map(([, , image]) => image));
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

// An operator alias outranks the name the player drew, on every board and back
// through their history -- the same reach a reroll has, since both are "what to
// call this id" rather than a property of one play.
//
// The reroll has to keep working underneath it: an alias is set once and a
// player goes on drawing names afterwards, so an implementation that dropped the
// handle lookup entirely would pass a test that only checked the override.
{
  const d = db([
    ['2026-08-01', 'p1', 'a.jpg', 100, 'Amber Basin'],
    ['2026-08-02', 'p1', 'b.jpg', 200, 'Winding Valley'],
    ['2026-08-02', 'p2', 'c.jpg', 50, 'Dusty Lookout'],
  ]);
  d.prepare('INSERT INTO players (player_id, alias, note) VALUES (?, ?, ?)')
    .run('p1', 'Phil', 'from the meetup');

  assert.deepEqual(board(d, DAILY, '2026-08-01'), [['Phil', 100]],
    'the alias did not reach a day that closed before it was set');
  assert.deepEqual(board(d, DAILY, '2026-08-02'), [['Phil', 200], ['Dusty Lookout', 50]],
    'the alias did not replace the drawn name, or displaced a player who has none');

  // A row that names nobody is not a name. Clearing an alias hands the player
  // back to their own, rather than leaving a board rendering nothing.
  d.prepare('UPDATE players SET alias = NULL WHERE player_id = ?').run('p1');
  assert.deepEqual(board(d, DAILY, '2026-08-02'), [['Winding Valley', 200], ['Dusty Lookout', 50]],
    'clearing the alias did not restore the drawn name');

  // The note is the half nothing serves. Asserted here because the only thing
  // standing between it and a stream overlay is which column the expression
  // reads.
  d.prepare('UPDATE players SET note = ? WHERE player_id = ?').run('secret', 'p1');
  assert.ok(!JSON.stringify(board(d, DAILY, '2026-08-02')).includes('secret'),
    'the private note reached the board');
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

// Which span each board asks for, which the query tests above cannot see: they
// hand the SQL its period themselves, so nothing above notices if the handler
// pairs the wrong one with it. Swapping the two serves a board that renders
// perfectly and carries the other board's numbers -- on an overlay, with no
// error and nothing on screen to read as wrong.
{
  const env = { ANSWERS: d1(schema()) };
  seedAnswers(env.ANSWERS.db, ['a.jpg']);
  const insert = env.ANSWERS.db.prepare(`INSERT INTO plays
    (date, player_id, image, km, points, handle) VALUES (?, ?, ?, ?, ?, ?)`);

  // The two spans as the handler computes them. Derived rather than fixed,
  // because both move with the clock: a board seeded on a hardcoded date is a
  // board with nothing on it tomorrow.
  const day = lastClosedDate();
  const month = monthOf();
  // Another date in the running month, so the monthly board holds a row the
  // daily board cannot -- which is what makes the two distinguishable.
  const other = `${month}-15` === day ? `${month}-16` : `${month}-15`;
  // Up to two days a month the last closed date belongs to the month before,
  // and the daily board's players are then absent from the monthly one.
  const bothBoards = day.startsWith(month);

  insert.run(day, 'p1', 'a.jpg', 1.0, 100, 'Amber Basin');
  insert.run(day, 'p2', 'a.jpg', 1.0, 400, 'Winding Valley');
  insert.run(other, 'p3', 'a.jpg', 1.0, 900, 'Lucky Overpass');
  insert.run('2020-01-01', 'p4', 'a.jpg', 1.0, 4000, 'Distant Shore');

  const get = async search => {
    const request = { url: `https://guessr.dana.lol/api/leaderboard${search}` };
    const res = await onRequestGet({ request, env });
    return [res.status, await res.json()];
  };

  const DAILY_ROWS = [['Winding Valley', 400], ['Amber Basin', 100]];
  const MONTHLY_ROWS = bothBoards
    ? [['Lucky Overpass', 900], ...DAILY_ROWS]
    : [['Lucky Overpass', 900]];

  // A board is one date, and it is the closed one. The 2020 player outscores
  // everybody and still does not place, which is the span doing the work rather
  // than the LIMIT.
  for (const search of ['?board=daily', '', '?other=1']) {
    assert.deepEqual(await get(search),
      [200, { board: 'daily', period: day, rows: DAILY_ROWS }],
      `"${search}" did not serve the daily board`);
  }

  assert.deepEqual(await get('?board=monthly'),
    [200, { board: 'monthly', period: month, rows: MONTHLY_ROWS }],
    'the monthly board is not the running month summed');

  // Anything else is refused rather than quietly served as one of the two --
  // a typo'd board is a bug in whatever is polling, and a board is the wrong
  // place to find out.
  for (const board of ['weekly', 'Daily', 'MONTHLY', 'all', "daily' OR 1=1"]) {
    assert.deepEqual(
      await get(`?board=${encodeURIComponent(board)}`),
      [400, { error: 'board must be daily or monthly' }],
      `"${board}" was accepted as a board`);
  }
}

console.log('ok: a reroll renames a player on every board, back through history');
console.log('ok: an operator alias outranks a drawn name, and its note stays private');
console.log('ok: a nameless play does not cost a player their name');
console.log('ok: the boards still rank by summed points over their own span');
console.log('ok: players sharing an alias are numbered apart on the board');
console.log('ok: both boards seek the name index instead of scanning per row');
console.log('ok: each board asks for its own span, and defaults to daily');
console.log('ok: a board that is neither daily nor monthly is refused');
