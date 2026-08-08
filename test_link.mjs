// Cover the device merge: what moves, what is kept when both browsers answered
// the same round, and what is left under the old id.
//
// Worth testing because the failure mode is losing plays, permanently and
// quietly. The merge rewrites rows in place with no undo, and the collision case
// -- the same round answered on both devices -- is the one a player produces by
// accident and nobody produces on purpose while clicking through `task dev`. A
// missing OR IGNORE fails the whole batch; a missing sweep leaves the duplicate
// behind, so the same round still counts twice and the board reads exactly as
// wrong as before the merge ran.
//
// It runs the real statements against a real SQLite over the real migrations
// ledger, so the only thing not exercised here is D1's binding layer.

import assert from 'node:assert/strict';
import { DatabaseSync } from 'node:sqlite';
import { MOVE, SWEEP, onRequestPost } from './functions/api/link.js';
import { linkUrl, parseLink } from './web/link.js';
import { d1, post, schema } from './_d1.mjs';

const SCHEMA = schema();

const PHONE = 'phone-id', DESKTOP = 'desktop-id', STRANGER = 'stranger-id';

function db(rows) {
  const d = new DatabaseSync(':memory:');
  d.exec(schema());
  const insert = d.prepare(`INSERT INTO plays
    (date, player_id, image, km, points, handle) VALUES (?, ?, ?, ?, ?, ?)`);
  for (const [player, image, points] of rows) {
    insert.run('2026-08-02', player, image, 1.0, points, 'Amber Basin');
  }
  return d;
}

// from -> to, the way the endpoint runs it.
function merge(d, from, to) {
  const moved = d.prepare(MOVE).run(to, from).changes;
  d.prepare(SWEEP).run(from);
  return moved;
}

const owned = (d, player) => d.prepare(
  'SELECT image, points FROM plays WHERE player_id = ? ORDER BY image').all(player)
  .map(r => [r.image, r.points]);

// The plain case: two devices, no round answered on both.
{
  const d = db([
    [PHONE, 'a.jpg', 100],
    [PHONE, 'b.jpg', 200],
    [DESKTOP, 'c.jpg', 300],
  ]);
  assert.equal(merge(d, PHONE, DESKTOP), 2, 'both of the phone\'s plays did not move');
  assert.deepEqual(owned(d, PHONE), [], 'the phone still owns plays after merging');
  assert.deepEqual(owned(d, DESKTOP),
    [['a.jpg', 100], ['b.jpg', 200], ['c.jpg', 300]],
    'the merged player is missing rounds from one device or the other');
  console.log('ok: a merge moves every play onto the id that was linked to');
}

// The collision: the same round answered on both devices. The score already on
// record under the target wins, matching the first-write-wins rule the primary
// key exists to enforce -- and crucially the loser is *gone*, not left under the
// old id where it would still be a second play of the same round.
{
  const d = db([
    [PHONE, 'a.jpg', 4000],
    [DESKTOP, 'a.jpg', 10],
  ]);
  assert.equal(merge(d, PHONE, DESKTOP), 0, 'a colliding row reported as moved');
  assert.deepEqual(owned(d, DESKTOP), [['a.jpg', 10]],
    'the merge overwrote the score already on record');
  assert.deepEqual(owned(d, PHONE), [],
    'the losing row survived under the old id, so the round still counts twice');
  console.log('ok: a round answered on both devices keeps the score on record, once');
}

// A merge touches exactly two players. Trivially true of the SQL, and the thing
// that would be catastrophic and silent if a WHERE ever went missing.
{
  const d = db([
    [PHONE, 'a.jpg', 100],
    [STRANGER, 'a.jpg', 500],
    [STRANGER, 'b.jpg', 500],
  ]);
  merge(d, PHONE, DESKTOP);
  assert.deepEqual(owned(d, STRANGER), [['a.jpg', 500], ['b.jpg', 500]],
    'the merge reached a player who was not part of it');
}

// Linking a browser that has never played is legitimate -- it is what happens
// when a player links the second device before playing on it -- and must not
// disturb the target.
{
  const d = db([[DESKTOP, 'a.jpg', 100]]);
  assert.equal(merge(d, PHONE, DESKTOP), 0);
  assert.deepEqual(owned(d, DESKTOP), [['a.jpg', 100]]);
  console.log('ok: a merge touches nobody else, and an unplayed device costs nothing');
}

// Same date, same image, different player: the primary key allows it, which is
// the premise the whole merge rests on. If it ever didn't, the collision above
// would be unreachable and this file would be testing nothing.
{
  const d = db([[PHONE, 'a.jpg', 100], [DESKTOP, 'a.jpg', 200]]);
  assert.equal(d.prepare('SELECT COUNT(*) AS n FROM plays').get().n, 2);
}

// The URL the code carries, and reading it back. The whole failure mode is that
// it arrives wrong -- a space in the name ending the fragment early, a key read
// under the wrong name -- and every version of that presents to a player as a
// QR code that did nothing.
{
  const id = 'b1c4f0e2-3a7d-4c19-9f8e-2d6a5b3c1e70';
  // Every origin the game is actually played on, because they differ in the
  // ways that break a URL: a bare host, a preview alias deep in subdomains, and
  // a local server on a port.
  for (const base of [
    'https://guessr.dana.lol/',
    'https://link.adanalife-guessr-staging.pages.dev/',
    'http://localhost:8000/',
  ]) {
    // The name has a space in it -- every alias does -- which is exactly what an
    // unescaped fragment loses.
    const url = linkUrl(base, id, 'Wandering Wildflower');
    assert.ok(url.startsWith(`${base}#`), `${url} did not build on its own origin`);
    assert.ok(!url.includes(' '), `${url} carries a raw space`);
    assert.deepEqual(parseLink(new URL(url).hash), { id, name: 'Wandering Wildflower' });
  }

  // Nameless is legal on both sides: a browser that cannot keep localStorage has
  // no alias to send, and the id is what does the linking.
  assert.deepEqual(parseLink(new URL(linkUrl('https://guessr.dana.lol/', id, null)).hash),
    { id, name: null });

  // Anything that isn't one of these links reads as no link at all, rather than
  // as a link to nowhere -- the page acts on the difference.
  for (const hash of ['', '#', '#name=Amber%20Basin', '#link=']) {
    assert.equal(parseLink(hash), null, `${hash || '(empty)'} parsed as a link`);
  }
  console.log('ok: the code carries an id and a name across origins, and back');
}

// The guard that decides whether any of the above runs at all.
//
// Worth reaching through the handler for rather than exporting as a predicate:
// what needs pinning is not that `from === to` compares two strings, it is that
// a self-link never reaches the statements. They are destructive on their own
// terms -- MOVE sets every row's player_id to the value it already holds, and
// SWEEP then deletes by that same id -- so on from === to the pair is a plain
// "delete this player's history", with the OR IGNORE that makes the merge safe
// contributing nothing.
//
// It is reachable: the page hands the id to the other device in a URL fragment,
// and opening your own link on the browser that drew it is the obvious misuse.
{
  const env = { ANSWERS: d1(SCHEMA) };
  const insert = env.ANSWERS.db.prepare(`INSERT INTO plays
    (date, player_id, image, km, points, handle) VALUES (?, ?, ?, ?, ?, ?)`);
  for (const image of ['a.jpg', 'b.jpg', 'c.jpg']) {
    insert.run('2026-08-02', PHONE, image, 1.0, 4000, 'Amber Basin');
  }

  const res = await onRequestPost({ request: post({ from: PHONE, to: PHONE }), env });
  assert.equal(res.status, 200, 'a self-link should be a no-op, not an error');
  assert.deepEqual(await res.json(), { moved: 0 });
  assert.equal(owned(env.ANSWERS.db, PHONE).length, 3,
    'a self-link deleted the player\'s entire history');

  console.log('ok: linking a browser to itself moves nothing and deletes nothing');
}

// The ids are the only credential the game has, so a request carrying anything
// that isn't one is refused before it can name rows.
{
  const env = { ANSWERS: d1(SCHEMA) };
  for (const body of [
    undefined,                            // not JSON at all
    null, 'string', 42,
    {}, { from: PHONE }, { to: DESKTOP },
    { from: '', to: DESKTOP },
    { from: PHONE, to: '' },
    { from: 42, to: DESKTOP },
    { from: PHONE, to: null },
    { from: 'x'.repeat(65), to: DESKTOP },
  ]) {
    const res = await onRequestPost({ request: post(body), env });
    assert.equal(res.status, 400, `accepted a bad link body: ${JSON.stringify(body)}`);
  }

  console.log('ok: a link request that is not two player ids is refused');
}

// And the ordinary merge, end to end through the handler rather than through the
// statements -- the batch is one transaction, so a half-applied merge would drop
// plays instead of moving them.
{
  const env = { ANSWERS: d1(SCHEMA) };
  const insert = env.ANSWERS.db.prepare(`INSERT INTO plays
    (date, player_id, image, km, points, handle) VALUES (?, ?, ?, ?, ?, ?)`);
  insert.run('2026-08-02', PHONE, 'a.jpg', 1.0, 100, 'Amber Basin');
  insert.run('2026-08-02', PHONE, 'b.jpg', 1.0, 200, 'Amber Basin');
  insert.run('2026-08-02', DESKTOP, 'b.jpg', 1.0, 300, 'Amber Basin');

  const res = await onRequestPost({ request: post({ from: PHONE, to: DESKTOP }), env });
  assert.deepEqual(await res.json(), { moved: 1 }, 'the collision should not count as moved');
  assert.deepEqual(owned(env.ANSWERS.db, PHONE), [], 'the old id kept rows after a merge');
  // b.jpg keeps the 300 already on record under the target: first write wins.
  assert.deepEqual(owned(env.ANSWERS.db, DESKTOP), [['a.jpg', 100], ['b.jpg', 300]]);

  console.log('ok: the endpoint merges two devices in one transaction');
}
