// Cover the clip endpoint: what it serves, what it refuses, and how long the
// answer may be cached.
//
// Worth testing because every way this can be wrong is quiet. A missing clip that
// answers with the site's HTML at status 200 is the failure the endpoint exists to
// turn into a 404 -- a green deploy of black panes, which happened for real on
// 2026-08-02. A content type of octet-stream is a `<video>` that plays nothing and
// reports no error. And an `immutable` header on a name that can be regenerated is
// a player stuck with the wrong footage for a year, with no way to clear it.
//
// The R2 stub below is the same bargain as _d1.mjs: it models the shape of the
// binding, not the service. Range and conditional parsing really live in the
// runtime, so what is pinned here is that this handler asks for them and renders
// whatever R2 hands back -- not that R2 parses `bytes=` correctly.
import assert from 'node:assert/strict';

import { onRequest } from './functions/clips/[[path]].js';

// The half of R2's binding this endpoint touches. `get` resolves the Range header
// the way the real one does, because the status and content-range this returns are
// computed from the shape it gets back.
const bucket = (objects) => ({
  async get(key, { range } = {}) {
    const body = objects[key];
    if (body === undefined) return null;
    const size = body.length;
    const spec = range?.get?.('range');
    const object = {
      size,
      httpEtag: `"${key}"`,
      writeHttpMetadata(headers) {
        headers.set('content-type', 'application/octet-stream');
      },
    };
    if (!spec) return { ...object, body, range: undefined };
    // `bytes=a-b`, `bytes=a-` and `bytes=-n`, which is the whole of what a video
    // element asks for.
    const [from, to] = spec.replace('bytes=', '').split('-');
    if (from === '') return { ...object, body, range: { suffix: Number(to) } };
    const offset = Number(from);
    const length = to === '' ? undefined : Number(to) - offset + 1;
    return { ...object, body, range: { offset, length } };
  },
});

const CLIP = 'clips/2018_0513_135618_039_opt-025000.mp4';
const LEGACY = 'clips/2018_0701_211825_079_opt.mp4';
const env = { CLIPS: bucket({ [CLIP]: 'x'.repeat(5000), [LEGACY]: 'y'.repeat(400) }) };

const call = (path, { method = 'GET', headers = {} } = {}) =>
  onRequest({
    request: new Request(`https://guessr.dana.lol/${path}`, { method, headers }),
    params: { path: path.replace(/^clips\//, '').split('/') },
    env,
  });

// The happy path, and the header that makes it playable at all.
let res = await call(CLIP);
assert.equal(res.status, 200);
assert.equal(res.headers.get('content-type'), 'video/mp4');
assert.equal(res.headers.get('accept-ranges'), 'bytes');
assert.equal(await res.text(), 'x'.repeat(5000));

// Set by the handler rather than inherited: the stub reports octet-stream, which
// is what an upload that forgot --content-type leaves behind. Serving that is a
// video element that plays nothing and says nothing.
assert.notEqual(res.headers.get('content-type'), 'application/octet-stream');

// A clip a manifest names but nothing uploaded. THE ONE THAT MATTERS: Pages
// answers an unknown path with the site's own HTML at status 200, so unless this
// is a real 404 a deploy whose media never arrived is green everywhere and black
// in the browser.
res = await call('clips/never-pushed-000000.mp4');
assert.equal(res.status, 404);
assert.equal(await res.text(), '');

// Only clips. Anything else is not this endpoint's job, and answering for it
// would mean the bucket's whole keyspace is reachable by URL.
for (const path of ['clips/notavideo.txt', 'clips/answers.sql', 'clips/', 'clips/nested/x.json']) {
  assert.equal((await call(path)).status, 404, path);
}

// Seeking. The frame zoom pauses and scrubs, so a range request is a real thing
// the player makes, and a 200-with-everything answer breaks it.
res = await call(CLIP, { headers: { range: 'bytes=100-199' } });
assert.equal(res.status, 206);
assert.equal(res.headers.get('content-range'), 'bytes 100-199/5000');

// An open-ended range, which is what a player asks for when it wants the rest.
res = await call(CLIP, { headers: { range: 'bytes=4000-' } });
assert.equal(res.status, 206);
assert.equal(res.headers.get('content-range'), 'bytes 4000-4999/5000');

// And a suffix range, counted from the end -- how the moov atom gets found in a
// file that was not written faststart.
res = await call(CLIP, { headers: { range: 'bytes=-500' } });
assert.equal(res.status, 206);
assert.equal(res.headers.get('content-range'), 'bytes 4500-4999/5000');

// No Range header means the whole thing, even though the stub would happily
// report a range: a 206 to a client that did not ask for one is a response some
// players refuse outright.
assert.equal((await call(CLIP)).status, 200);

console.log('ok: a clip streams, seeks, and a missing one is a 404 rather than the site');

// How long the answer may be cached, which is decided by whether the name can
// mean two different sets of bytes. `<slug>-<ms>.mp4` names one moment and can be
// held forever; a bare `<slug>.mp4` is what a regeneration can quietly replace.
res = await call(CLIP);
assert.match(res.headers.get('cache-control'), /max-age=31536000/);
assert.match(res.headers.get('cache-control'), /immutable/);

res = await call(LEGACY);
assert.match(res.headers.get('cache-control'), /max-age=3600/);
assert.doesNotMatch(
  res.headers.get('cache-control'),
  /immutable/,
  'a name a regeneration can reuse must not be cached as immutable -- a player ' +
    'would be stuck with footage that no longer matches its answer',
);

console.log('ok: only a name carrying its moment is cached as immutable');

// Writes have no business here. Not a security boundary -- the binding is
// read-only by intent -- but a 405 says so rather than falling through to a 404,
// which reads as "wrong URL" and sends someone looking in the wrong place.
for (const method of ['POST', 'PUT', 'DELETE']) {
  res = await call(CLIP, { method });
  assert.equal(res.status, 405, method);
  assert.equal(res.headers.get('allow'), 'GET, HEAD');
}

// HEAD goes down the GET path and the runtime drops the body, so what matters is
// that the headers a player needs to size the file are all there.
res = await call(CLIP, { method: 'HEAD' });
assert.equal(res.status, 200);
assert.equal(res.headers.get('content-type'), 'video/mp4');

console.log('ok: HEAD is answered like GET, and a write is refused as one');
