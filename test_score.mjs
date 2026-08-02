// Cover the scoring math and the guess validator.
//
// Worth testing because both fail silently. A broken distance still returns a
// plausible number of points, and a validator that lets a non-number through
// scores every guess as a perfect one -- NaN km makes exp(-NaN) NaN, and
// Math.round(NaN) is 0 in some paths and 5000-adjacent nonsense in others.
// Neither shows up as an error anywhere.
//
// The handler itself is glue (unwrap the request, one indexed D1 lookup, respond)
// and is exercised by actually running `task dev` against a local D1.

import assert from 'node:assert/strict';
import {
  MAX_HANDLE, MAX_ROUND_SCORE, haversineKm, isPlay, parseGuess, parsePlay, scoreFor,
} from './functions/_scoring.mjs';
import { ADJECTIVES, NOUNS, aliasFrom } from './web/alias.js';

const SF = { lat: 37.7749, lng: -122.4194 };
const NYC = { lat: 40.7128, lng: -74.0060 };

// Known distance, ~4130 km great-circle. 1% tolerance covers the earth-radius
// choice without letting a genuinely wrong formula through.
const sfToNyc = haversineKm(SF, NYC);
assert.ok(Math.abs(sfToNyc - 4130) < 41, `SF->NYC came out at ${sfToNyc} km`);

assert.equal(haversineKm(SF, SF), 0, 'a point is not zero km from itself');
// Symmetric, and unbothered by crossing the antimeridian.
assert.equal(haversineKm(SF, NYC), haversineKm(NYC, SF));
assert.ok(haversineKm({ lat: 0, lng: 179 }, { lat: 0, lng: -179 }) < 250,
  'crossing the antimeridian went the long way round');

assert.equal(scoreFor(0), MAX_ROUND_SCORE, 'an exact guess is not full marks');
assert.ok(scoreFor(sfToNyc) < 50, 'a continent away still scores points');
// Monotonic: further is always worth less, which is the property the curve exists
// to have.
for (const [near, far] of [[0, 1], [1, 10], [10, 100], [100, 1000]]) {
  assert.ok(scoreFor(near) > scoreFor(far), `${near} km scored no better than ${far}`);
}

// The validator. Each of these reaching haversineKm produces a score rather than
// an error, so they have to be rejected here or not at all.
const good = { image: 'clips/a.mp4', lat: 40, lng: -100 };
assert.deepEqual(parseGuess(good), good);
assert.deepEqual(parseGuess({ ...good, extra: 'ignored' }), good, 'extra keys should be dropped');

for (const bad of [
  null, undefined, 'string', 42, [],
  { ...good, lat: '40' },              // JSON string, not a number
  { ...good, lat: null },
  { ...good, lng: undefined },
  { ...good, lat: NaN },
  { ...good, lng: Infinity },
  { ...good, lat: 91 },                // off the planet
  { ...good, lat: -91 },
  { ...good, lng: 181 },
  { ...good, lng: -181 },
  { ...good, image: '' },
  { ...good, image: 42 },
  { ...good, image: 'x'.repeat(201) },  // unbounded key into the answers lookup
  {},
]) {
  assert.equal(parseGuess(bad), null, `accepted a bad guess: ${JSON.stringify(bad)}`);
}

// Boundaries are guesses, not errors -- someone can legitimately pin the poles or
// the antimeridian.
for (const edge of [
  { ...good, lat: 90 }, { ...good, lat: -90 },
  { ...good, lng: 180 }, { ...good, lng: -180 },
  { ...good, lat: 0, lng: 0 },
]) {
  assert.notEqual(parseGuess(edge), null, `rejected a legal edge guess: ${JSON.stringify(edge)}`);
}

// The play context: what turns a scored guess into a row on the leaderboard.
// isPlay and parsePlay are separate for a reason worth pinning -- a body that
// means to be recorded and fails validation must be distinguishable from one
// that never asked to be, or the handler answers a malformed play with a
// perfectly normal score that silently never reaches the board.
const play = { date: '2026-08-01', player_id: 'a3f1c2d4-0000-4000-8000-000000000000' };
assert.deepEqual(parsePlay(play), { date: play.date, playerId: play.player_id, handle: null });

assert.equal(isPlay({ ...good }), false, 'a practice guess claimed to be a play');
assert.equal(isPlay(play), true);
assert.equal(parsePlay({ ...good }), null, 'a practice guess parsed as a play');
// The pairing the handler relies on: not a play at all, versus a broken one.
assert.equal(isPlay({ ...play, date: 'yesterday' }), true, 'a broken date stopped being a play');
assert.equal(parsePlay({ ...play, date: 'yesterday' }), null);

// The handle is optional, trimmed, and never an identity.
const alias = aliasFrom(() => 0); // the first adjective and the first noun
assert.equal(parsePlay({ ...play, handle: `  ${alias}  ` }).handle, alias);
assert.equal(parsePlay({ ...play, handle: '' }).handle, null, 'empty handle should be absent');
assert.equal(parsePlay({ ...play, handle: '   ' }).handle, null, 'blank handle should be absent');
assert.equal(parsePlay({ ...play, handle: null }).handle, null);
assert.equal(parsePlay({ ...play, handle: 42 }), null, 'a non-string handle is not a handle');

// Only a name the wordlist could have produced is kept. This is what makes that
// list a boundary rather than a client-side convention: /api/score is reachable
// directly, so anything accepted here can be put on a live broadcast by anyone
// with a terminal.
for (const forged of [
  'GO WATCH SOMEONE ELSE',
  'adanalife_',
  'Jason',                                  // a plausible name is still not an alias
  `${ADJECTIVES[0]}`,                       // half of one
  `${NOUNS[0]}`,
  `${NOUNS[0]} ${ADJECTIVES[0]}`,           // the right words, the wrong way round
  `${ADJECTIVES[0]} ${NOUNS[0]} ${NOUNS[1]}`, // an alias with something appended
  `${ADJECTIVES[0]}  ${NOUNS[0]}`,          // two spaces
  `${ADJECTIVES[0]} ${NOUNS[0]} `.repeat(2).trim(),
  `${ADJECTIVES[0].toLowerCase()} ${NOUNS[0]}`, // case is part of the list
  '<script>alert(1)</script>',
  'x'.repeat(200),
]) {
  assert.equal(parsePlay({ ...play, handle: forged }).handle, null,
    `a forged handle was kept: ${JSON.stringify(forged)}`);
}

// Dropped, not rejected -- the guess was still earned, so it records nameless
// rather than failing the round.
assert.ok(parsePlay({ ...play, handle: 'GO WATCH SOMEONE ELSE' }),
  'a forged handle should drop the name, not the play');

// Every alias the generator can produce survives the round trip, or a player
// would silently lose their name to the validator that is meant to protect it.
for (const adjective of ADJECTIVES) {
  for (const noun of NOUNS) {
    const name = `${adjective} ${noun}`;
    assert.equal(parsePlay({ ...play, handle: name }).handle, name,
      `the generator can produce "${name}" but parsePlay drops it`);
    assert.ok(name.length <= MAX_HANDLE, `"${name}" is longer than MAX_HANDLE`);
  }
}

// Two players wearing the same alias are still two players.
const twins = [play, { ...play, player_id: 'b7e2' }].map(b => parsePlay({ ...b, handle: alias }));
assert.notEqual(twins[0].playerId, twins[1].playerId, 'the handle collapsed two players into one');

for (const bad of [
  { ...play, date: '2026-8-1' },        // unpadded, and the board matches literally
  { ...play, date: '2026-13-01' },      // Invalid Date -- toISOString would throw
  { ...play, date: '2026-01-32' },
  { ...play, date: '2026-02-31' },      // parses, but Date rolls it forward to Mar 3
  { ...play, date: '2026-02-29' },      // not a leap year
  { ...play, date: '01-08-2026' },
  { ...play, date: '2026-08-01T00:00:00Z' },
  { ...play, date: 20260801 },
  { ...play, date: null },
  { ...play, player_id: '' },
  { ...play, player_id: 42 },
  { ...play, player_id: 'x'.repeat(65) },
  { date: play.date },                  // a date with nobody attached to it
]) {
  assert.equal(parsePlay(bad), null, `accepted a bad play: ${JSON.stringify(bad)}`);
}

// Leap days are real days and must be playable.
assert.ok(parsePlay({ ...play, date: '2028-02-29' }), 'rejected a real leap day');

console.log('ok: scoring curve and guess validation');
console.log('ok: a play is keyed on an opaque id, with the handle as a label only');
console.log('ok: only a name the wordlist could have made is kept');
