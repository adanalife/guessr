// Cover /admin/guesses: the heat layer's feed is coordinates and nothing else.
//
// Two properties worth pinning. A play from before the coordinate columns
// existed is skipped rather than served as a null point -- those rows are
// permanent, so the filter is load-bearing forever, not just across one
// migration. And the response carries no date, player or score: the endpoint's
// whole contract is "here", and a column added to its SELECT is a disclosure
// decision, not a convenience.
//
// Against the real migrations over node:sqlite, so the filter runs on the
// schema a deployed database actually has.
import assert from 'node:assert/strict';

import { d1, schema } from './_d1.mjs';
import { onRequestGet } from './functions/admin/guesses.js';

const answers = d1(schema());
const insert = answers.db.prepare(
  `INSERT INTO plays (date, player_id, image, km, points, handle, guess_lat, guess_lng)
   VALUES (?, ?, 'clips/a-000001.mp4', 12.3, 4000, NULL, ?, ?)`,
);
insert.run('2026-08-01', 'p1', 41.5, -87.5);
insert.run('2026-08-02', 'p2', 35.1, -106.6);
// A pre-coordinate play: km and points recorded, pin location never was.
insert.run('2026-07-01', 'p3', null, null);

const res = await onRequestGet({ env: { ANSWERS: answers } });
const body = await res.json();

assert.equal(res.status, 200);
assert.deepEqual(
  body.guesses.sort(),
  [[35.1, -106.6], [41.5, -87.5]],
  'every coordinated play as a bare [lat, lng] pair, uncoordinated ones skipped',
);
assert.equal(res.headers.get('cache-control'), 'no-store');

console.log('ok: coordinates only -- bare pairs out, uncoordinated plays skipped');
