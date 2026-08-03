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
import { readFileSync } from 'node:fs';
import { DatabaseSync } from 'node:sqlite';
import { label, onRequestGet, query } from './functions/api/leaderboard.js';
import { ADJECTIVES, NOUNS } from './web/alias.js';
import { lastClosedDate, monthOf } from './web/daily.js';
import { d1 } from './_d1.mjs';

const SCHEMA = readFileSync('schema.sql', 'utf8');

const DAILY = query('= ?');
const MONTHLY = query("LIKE ? || '-%'");

// played_at is a plain string column, so a test can hand-place rows in time
// rather than sleep through a second to separate two of them.
let tick = 0;
const at = () => `2026-08-01 12:00:${String(tick++).padStart(2, '0')}`;

function db(rows) {
  const d = new DatabaseSync(':memory:');
  d.exec(SCHEMA);
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

console.log('ok: a reroll renames a player on every board, back through history');
console.log('ok: a nameless play does not cost a player their name');
console.log('ok: the boards still rank by summed points over their own span');
console.log('ok: players sharing an alias are numbered apart on the board');

// The handler over that query: which board was asked for, which span that means,
// and what a row looks like by the time the overlay reads it.
//
// The span is the whole risk. Both boards are the same SQL and differ only in
// the period bound into it, so swapping which one a request gets is invisible
// everywhere -- the response is well-formed, the names are real, the totals add
// up, and it renders as an ordinary board carrying a month's scores under
// today's date. Inverting that fork survived the suite until this ran.
//
// No clock is injected because the handler takes none: it calls lastClosedDate()
// and monthOf() itself. So the test asks those same functions what today means
// and seeds against the answer, which also keeps it honest across a month
// boundary -- on the 1st and 2nd the last closed date is in the previous month,
// and a test that assumed otherwise would fail twice a month for the wrong
// reason.
{
  const DAY = lastClosedDate();
  const MONTH = monthOf();
  // A second date inside the month that is not the daily one, so the two boards
  // cannot agree by accident and a swapped fork has something to be caught by.
  const OTHER = `${MONTH}-15` === DAY ? `${MONTH}-16` : `${MONTH}-15`;
  const dayIsInMonth = DAY.startsWith(MONTH);

  const get = board => ({
    url: 'https://guessr.dana.lol/api/leaderboard'
      + (board === undefined ? '' : `?board=${board}`),
  });

  function env(rows) {
    const binding = d1(SCHEMA);
    const insert = binding.db.prepare(`INSERT INTO plays
      (date, player_id, image, km, points, handle) VALUES (?, ?, ?, ?, ?, ?)`);
    for (const [date, player, points, handle] of rows) {
      insert.run(date, player, 'a.jpg', 1.0, points, handle);
    }
    return { ANSWERS: binding };
  }

  const rows = [
    [DAY, 'p-day', 100, 'Amber Basin'],
    [OTHER, 'p-month', 900, 'Winding Valley'],
  ];

  // The daily board is one date -- the last one that can no longer change --
  // and must not pick up the rest of the month.
  {
    const res = await onRequestGet({ request: get('daily'), env: env(rows) });
    assert.equal(res.status, 200);
    const body = await res.json();
    assert.equal(body.board, 'daily');
    assert.equal(body.period, DAY, 'the daily board is not the last closed date');
    assert.deepEqual(body.rows, [['Amber Basin', 100]],
      'the daily board carried scores from outside its date');
  }

  // The monthly board is the running month, today included.
  {
    const res = await onRequestGet({ request: get('monthly'), env: env(rows) });
    const body = await res.json();
    assert.equal(body.board, 'monthly');
    assert.equal(body.period, MONTH, 'the monthly board is not the current month');
    assert.deepEqual(body.rows, dayIsInMonth
      ? [['Winding Valley', 900], ['Amber Basin', 100]]
      : [['Winding Valley', 900]],
      'the monthly board is not the whole month, best first');
  }

  // No parameter is the daily board. The overlay omits it, so this is the path
  // that actually runs on the stream.
  {
    const body = await (await onRequestGet({ request: get(), env: env(rows) })).json();
    assert.equal(body.board, 'daily');
    assert.equal(body.period, DAY, 'the default board is not the daily one');
  }

  // An empty value is the same as no value: `?board=` reads as unset and gets
  // the default, rather than being a typo worth a 400. Pinned because it is the
  // one input where "refuse anything unrecognised" and "default when absent"
  // disagree, and a bot building the URL from an empty variable produces exactly
  // this.
  {
    const body = await (await onRequestGet({ request: get(''), env: env(rows) })).json();
    assert.equal(body.board, 'daily', '?board= should read as unset');
    assert.equal(body.period, DAY);
  }

  // Anything else is refused rather than quietly served as a daily board, which
  // would make a typo in the bot look like a working request.
  for (const bad of ['weekly', 'DAILY', 'Daily', 'daily ', 'all', '1', 'monthly;--']) {
    const res = await onRequestGet({ request: get(encodeURIComponent(bad)), env: env(rows) });
    assert.equal(res.status, 400, `accepted board=${JSON.stringify(bad)}`);
    assert.deepEqual(await res.json(), { error: 'board must be daily or monthly' });
  }

  // A player with no name renders as the placeholder rather than a null the
  // overlay would have to handle, and several of them are numbered apart.
  {
    const res = await onRequestGet({
      request: get('daily'),
      env: env([
        [DAY, 'p1', 300, null],
        [DAY, 'p2', 200, null],
        [DAY, 'p3', 100, 'Amber Basin'],
      ]),
    });
    assert.deepEqual((await res.json()).rows,
      [['anonymous (1)', 300], ['anonymous (2)', 200], ['Amber Basin', 100]],
      'nameless players did not render as numbered placeholders');
  }

  // Numbering is applied by the handler, not just available from label().
  {
    const res = await onRequestGet({
      request: get('daily'),
      env: env([[DAY, 'p1', 300, 'Amber Basin'], [DAY, 'p2', 100, 'Amber Basin']]),
    });
    assert.deepEqual((await res.json()).rows,
      [['Amber Basin (1)', 300], ['Amber Basin (2)', 100]],
      'two players sharing an alias reached the overlay as one name twice');
  }

  // Ten rows, however many played. The overlay renders five; the rest is room
  // for the bot to filter without a second request.
  {
    const many = Array.from({ length: 14 }, (_, i) => [DAY, `p${i}`, (i + 1) * 100, null]);
    const body = await (await onRequestGet({ request: get('daily'), env: env(many) })).json();
    assert.equal(body.rows.length, 10, `the board returned ${body.rows.length} rows`);
    assert.equal(body.rows[0][1], 1400, 'the board is not the top scores');
  }

  // An empty board is an empty board, not an error -- a date nobody played is
  // ordinary, and the bot drops a rotation slot rather than logging a failure.
  {
    const res = await onRequestGet({ request: get('daily'), env: env([]) });
    assert.equal(res.status, 200);
    assert.deepEqual((await res.json()).rows, []);
  }

  // The bot polls on its own timer, so the cache header is what stops a retry
  // loop reaching D1 on every tick.
  {
    const res = await onRequestGet({ request: get('daily'), env: env(rows) });
    assert.equal(res.headers.get('content-type'), 'application/json');
    assert.match(res.headers.get('cache-control'), /max-age=\d+/,
      'the board is served uncached, so a polling bot hits D1 every time');
  }

  console.log('ok: each board is served for its own span, and nothing else is served at all');
}
