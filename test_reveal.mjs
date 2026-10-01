// "Here's where you guessed": the nearest-still lookup /api/score runs on every
// guess, and the route that serves the stills.
//
// The lookup fails quietly in both directions -- a wrong window finds nothing and
// the page just shows no link, a missing cap shows a picture of somewhere 200 km
// away as "here" -- and it runs inside the one endpoint the game cannot lose, so
// the case that matters most is that its failure never becomes the guess's.

import assert from 'node:assert/strict';
import { d1, post, schema } from './_d1.mjs';
import { REVEAL_KM, nearestReveal, onRequestPost } from './functions/api/score.js';
import { onRequestGet } from './functions/reveals/[name].js';

const env = { ANSWERS: d1(schema()) };
const put = env.ANSWERS.db.prepare('INSERT INTO reveals (image, lat, lng) VALUES (?, ?, ?)');
put.run('2000_-5000.jpg', 40.00, -100.00);
put.run('2000_-4999.jpg', 40.01, -99.98);
// ~0.3 degrees of longitude east of the pin below: ~22 km at 48N, inside the cap,
// but outside a window that forgot to widen longitude by 1/cos(lat).
put.run('2400_-5985.jpg', 48.0, -119.7);

// Nearest wins, and the km is the real distance to it.
const near = await nearestReveal(env, { lat: 40.009, lng: -99.981 });
assert.equal(near.image, 'reveals/2000_-4999.jpg', 'picked a further still');
assert.ok(near.km < 0.2, `nearest still reported as ${near.km} km`);

// Longitude degrees shrink with latitude, so the window has to grow to match.
const north = await nearestReveal(env, { lat: 48.0, lng: -120.0 });
assert.equal(north?.image, 'reveals/2400_-5985.jpg',
  'a still 22 km east at 48N fell outside the window');

// Past the cap the pin is off every road the van drove: nothing, rather than a
// picture of somewhere else labelled as the guess.
assert.equal(await nearestReveal(env, { lat: 40.0, lng: -99.6 }), null,
  `a still ~34 km away was offered, past REVEAL_KM (${REVEAL_KM})`);
assert.equal(await nearestReveal(env, { lat: 25, lng: -80 }), null);
// The window is a square and the cap is a circle, so a still off the corner --
// ~30 km on the diagonal, inside the box on both axes -- is the one only the cap
// refuses.
assert.equal(await nearestReveal(env, { lat: 40.2, lng: -99.74 }), null,
  'a still ~30 km away on the diagonal was offered');

// A tier whose deploy is ahead of its migrations has no reveals table. That has
// to be no reveal, not a thrown query taking the score down with it.
// Practice scores only a round from a closed date, so each guess below is
// scheduled on one.
const closed = new Date(Date.now() - 5 * 86400000).toISOString().slice(0, 10);
const bare = { ANSWERS: d1(`CREATE TABLE answers (image TEXT PRIMARY KEY, lat REAL, lng REAL, state TEXT, filmed TEXT);
  CREATE TABLE round_days (date TEXT, position INTEGER, image TEXT);`) };
assert.equal(await nearestReveal(bare, { lat: 40, lng: -100 }), null);
bare.ANSWERS.db.prepare("INSERT INTO answers VALUES ('clips/a-000001.mp4', 40, -100, 'NE', '2018-06-01')").run();
bare.ANSWERS.db.prepare("INSERT INTO round_days VALUES (?, 1, 'clips/a-000001.mp4')").run(closed);
const scoredBare = await onRequestPost({
  request: post({ image: 'clips/a-000001.mp4', lat: 40, lng: -100 }), env: bare,
});
assert.equal(scoredBare.status, 200, 'a missing reveals table broke scoring');
assert.equal((await scoredBare.json()).reveal, null);

// And through the handler, on a practice guess: the reveal rides beside the score.
env.ANSWERS.db.prepare("INSERT INTO answers VALUES ('clips/b-000001.mp4', 44, -110, 'WY', '2018-07-01')").run();
env.ANSWERS.db.prepare(
  `INSERT INTO rounds (image, median_km, mean_cos, batch, slug, source_ts_sec, clip_ts_sec, radius_m)
   VALUES ('clips/b-000001.mp4', 10, 0.07, 'test', 'slug', 20, 20, 60)`).run();
env.ANSWERS.db.prepare("INSERT INTO round_days VALUES (?, 1, 'clips/b-000001.mp4')").run(closed);
const res = await onRequestPost({
  request: post({ image: 'clips/b-000001.mp4', lat: 40.0, lng: -100.0 }), env,
});
const body = await res.json();
assert.equal(body.reveal.image, 'reveals/2000_-5000.jpg');
assert.ok(body.km > 500, 'the reveal replaced the score rather than riding beside it');

// The route serves a cell's still and nothing else in the bucket.
const bucket = new Map([['reveals/2000_-5000.jpg', 'jpeg'], ['clips/b-000001.mp4', 'mp4']]);
const CLIPS = {
  get: async key => (bucket.has(key) ? { body: bucket.get(key), httpEtag: '"e"' } : null),
};
const got = await onRequestGet({ params: { name: '2000_-5000.jpg' }, env: { CLIPS } });
assert.equal(got.status, 200);
assert.equal(got.headers.get('content-type'), 'image/jpeg');
for (const name of ['b-000001.mp4', '../clips/b-000001.mp4', '2000_-5000.png', '1_2.jpg.mp4', '9_9.jpg']) {
  const miss = await onRequestGet({ params: { name }, env: { CLIPS } });
  assert.equal(miss.status, 404, `served ${name}`);
}

console.log('ok: the nearest still within REVEAL_KM, widened for latitude, never at the score\'s expense');
console.log('ok: the reveals route serves cell stills and nothing else');
