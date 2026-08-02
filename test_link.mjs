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
// It runs the real statements against a real SQLite over the real schema.sql, so
// the only thing not exercised here is D1's binding layer.

import assert from 'node:assert/strict';
import { readFileSync } from 'node:fs';
import { DatabaseSync } from 'node:sqlite';
import { MOVE, SWEEP } from './functions/api/link.js';
import { linkUrl, parseLink } from './web/link.js';

const PHONE = 'phone-id', DESKTOP = 'desktop-id', STRANGER = 'stranger-id';

function db(rows) {
  const d = new DatabaseSync(':memory:');
  d.exec(readFileSync('schema.sql', 'utf8'));
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
