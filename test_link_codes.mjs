// Cover link codes: a device with history issues one, another claims it and
// merges onto that player.
//
// The claim runs the same destructive MOVE+SWEEP as /api/link, so the cases are
// about who it must never reach: a code that expired, a code claimed already, a
// code typed into the device that drew it. Each of those is a merge nobody
// asked for, or a history deleted by a self-merge.

import assert from 'node:assert/strict';
import { onRequestPost as claim } from './functions/api/link/claim.js';
import { ALPHABET, LENGTH, newCode, onRequestPost as issue } from './functions/api/link/code.js';
import { d1, post, schema, seedAnswers } from './_d1.mjs';

const SCHEMA = schema();
const PHONE = 'phone-id', DESKTOP = 'desktop-id';

function world() {
  const env = { ANSWERS: d1(SCHEMA) };
  seedAnswers(env.ANSWERS.db, ['a.jpg', 'b.jpg']);
  const insert = env.ANSWERS.db.prepare(`INSERT INTO plays
    (date, player_id, image, km, points, handle) VALUES (?, ?, ?, ?, ?, ?)`);
  insert.run('2026-08-02', PHONE, 'a.jpg', 1.0, 100, 'Amber Basin');
  insert.run('2026-08-02', PHONE, 'b.jpg', 1.0, 200, 'Amber Basin');
  insert.run('2026-08-02', DESKTOP, 'b.jpg', 1.0, 300, 'Amber Basin');
  return env;
}

const owned = (env, player) => env.ANSWERS.db.prepare(
  'SELECT image, points FROM plays WHERE player_id = ? ORDER BY image').all(player)
  .map(r => [r.image, r.points]);
const call = async (handler, env, body) => {
  const res = await handler({ request: post(body), env });
  return [res.status, await res.json()];
};
const codes = env => env.ANSWERS.db.prepare('SELECT code FROM link_codes').all().length;

for (let i = 0; i < 200; i++) {
  const code = newCode();
  assert.equal(code.length, LENGTH);
  assert.ok([...code].every(c => ALPHABET.includes(c)), code);
}
assert.ok(!/[01OI]/.test(ALPHABET), 'the alphabet carries a letter that reads as another');
console.log('ok: codes are drawn from the unambiguous alphabet');

{
  const env = world();
  for (const body of [undefined, null, {}, { player_id: '' }, { player_id: 42 },
    { player_id: 'x'.repeat(65) }]) {
    assert.equal((await call(issue, env, body))[0], 400, JSON.stringify(body));
  }
  for (const body of [undefined, null, {}, { code: 'ABCDEFGH' }, { from: PHONE },
    { code: 'ABCDEFG', from: PHONE }, { code: 'ABCDEFG0', from: PHONE },
    { code: 42, from: PHONE }, { code: 'ABCDEFGH', from: '' }]) {
    assert.equal((await call(claim, env, body))[0], 400, JSON.stringify(body));
  }
  console.log('ok: a code request or a claim that is not well formed is refused');
}

// The whole round trip: the desktop has the history and asks; the phone types
// the code in, its plays fold onto the desktop, and it is told to be the desktop.
{
  const env = world();
  const [status, issued] = await call(issue, env, { player_id: DESKTOP });
  assert.equal(status, 200);
  assert.match(issued.expires_at, /^\d{4}-\d\d-\d\dT\d\d:\d\d:\d\dZ$/);
  const ttl = Date.parse(issued.expires_at) - Date.now();
  assert.ok(ttl > 9 * 60e3 && ttl <= 10 * 60e3 + 1e3, `ttl ${ttl}ms is not ten minutes`);

  // Typed the way a person types it: lower case, split in two.
  const typed = `${issued.code.slice(0, 4).toLowerCase()} - ${issued.code.slice(4)}`;
  assert.deepEqual(await call(claim, env, { code: typed, from: PHONE }),
    [200, { player_id: DESKTOP, moved: 1 }]);
  assert.deepEqual(owned(env, PHONE), []);
  // b.jpg keeps the 300 already on record under the desktop: first write wins.
  assert.deepEqual(owned(env, DESKTOP), [['a.jpg', 100], ['b.jpg', 300]]);

  assert.deepEqual(await call(claim, env, { code: issued.code, from: 'third-id' }),
    [404, { error: 'unknown or expired code' }], 'a code worked twice');
  assert.equal(codes(env), 0);
  console.log('ok: a claimed code merges onto the issuing player, once');
}

{
  const env = world();
  const [, first] = await call(issue, env, { player_id: DESKTOP });
  const [, second] = await call(issue, env, { player_id: DESKTOP });
  assert.equal(codes(env), 1, 'a player holds more than one live code');
  assert.equal((await call(claim, env, { code: first.code, from: PHONE }))[0], 404,
    'a replaced code still claims');
  assert.equal((await call(claim, env, { code: second.code, from: PHONE }))[0], 200);
  console.log('ok: asking again replaces the earlier code');
}

// Expired is refused and swept, by a claim of any code.
{
  const env = world();
  env.ANSWERS.db.prepare(`INSERT INTO link_codes VALUES ('ABCDEFGH', ?, '2020-01-01T00:00:00Z')`)
    .run(DESKTOP);
  assert.equal((await call(claim, env, { code: 'ABCDEFGH', from: PHONE }))[0], 404);
  assert.equal(owned(env, PHONE).length, 2, 'an expired code merged');
  assert.equal(codes(env), 0, 'the expired code was not swept');
  console.log('ok: an expired code is refused and swept');
}

// Typed into the device that drew it: nothing moves and, crucially, nothing is
// deleted -- MOVE+SWEEP with from === to is "delete this player's history".
{
  const env = world();
  const [, issued] = await call(issue, env, { player_id: PHONE });
  assert.deepEqual(await call(claim, env, { code: issued.code, from: PHONE }),
    [200, { player_id: PHONE, moved: 0 }]);
  assert.equal(owned(env, PHONE).length, 2, 'a self-claim deleted the player\'s history');
  console.log('ok: claiming your own code moves nothing and deletes nothing');
}
