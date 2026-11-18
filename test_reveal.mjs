// The route that serves the "here's where you guessed" stills. The lookup that
// picks one lives in server/score.py and is covered by test_server_score.py;
// what is pinned here is that the route serves a cell's still and nothing else
// in the bucket, since /api/score hands these names out for any pin at all.

import assert from 'node:assert/strict';
import { onRequestGet } from './functions/reveals/[name].js';

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

console.log('ok: the reveals route serves cell stills and nothing else');
