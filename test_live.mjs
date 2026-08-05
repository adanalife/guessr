// Cover the live-stream resolver: which feed bytes yield a video id.
//
// Worth testing because the failure is silent in the direction that matters. Too
// strict and the end-of-game board never shows the stream, and nothing anywhere
// says so -- the cell just stays a link, which is exactly how the previous
// resolver stayed broken through two releases. Too loose and a malformed id goes
// straight into an embed URL.
//
// The fixture is the real feed shape, trimmed: Atom, entries newest-first, each
// carrying a `<yt:videoId>`. The shape worth pinning is that the FIRST id wins,
// because that is the whole reason this reads a feed -- the newest entry is the
// current broadcast, and picking any other would embed an old drive.
import assert from 'node:assert/strict';
import { newestVideoId, onRequestGet } from './functions/api/live.js';

const entry = (id, title) =>
  `<entry><yt:videoId>${id}</yt:videoId><title>${title}</title></entry>`;
const feed = (...entries) =>
  `<?xml version="1.0" encoding="UTF-8"?><feed xmlns:yt="http://www.youtube.com/xml/schemas/2015">` +
  `<title>A Dana Life</title>${entries.join('')}</feed>`;

const live = feed(
  entry('Uhln8S-ZCMI', '24/7 Driving Around the USA'),
  entry('GS3hnGlX5xI', 'an older drive'),
);

assert.equal(newestVideoId(live), 'Uhln8S-ZCMI', 'the newest entry wins, not any later one');
assert.equal(newestVideoId(feed()), null, 'a feed with no entries yields nothing');
assert.equal(newestVideoId(''), null, 'an empty body yields nothing rather than throwing');
// The id goes straight into an embed URL, so anything that is not exactly a
// YouTube id has to be refused rather than passed along.
assert.equal(newestVideoId(feed(entry('short', 'too short'))), null,
  'an id of the wrong length is refused');
assert.equal(newestVideoId('<yt:videoId>Uhln8S-ZCMI'), null,
  'an unclosed element is not an id');
// A channel whose newest video is not a broadcast still answers that video. There
// is no keyless way to tell, and the cell is captioned with a link rather than a
// claim that the player is live.
assert.equal(newestVideoId(feed(entry('wX2DVKMKF_Y', 'WoodenBoat School 2024'))), 'wX2DVKMKF_Y',
  'the newest video answers even when it is not the stream');
console.log('ok: the newest feed entry yields its id, and nothing else does');

// The endpoint's own contract: JSON, cached, and a link-only cell whenever the
// upstream read fails -- an exception here would leave the board's sixth cell
// empty rather than degraded.
const withFetch = async (impl) => {
  const real = globalThis.fetch;
  globalThis.fetch = impl;
  try { return await onRequestGet(); } finally { globalThis.fetch = real; }
};

let res = await withFetch(async () => new Response(live, { status: 200 }));
let body = await res.json();
assert.equal(body.videoId, 'Uhln8S-ZCMI');
assert.deepEqual(body.why, { status: 200, bytes: live.length });
assert.match(res.headers.get('cache-control'), /^public, max-age=\d+$/,
  'the answer is cacheable, so one upstream read serves many finished games');

// Each failure leaves the board its link and is distinct in `why`, which is the
// point of carrying it: a resolver that can never resolve anything has to be
// tellable apart from a channel with nothing to show.
const empty = '<feed></feed>';
res = await withFetch(async () => new Response(empty, { status: 200 }));
body = await res.json();
assert.equal(body.videoId, null);
assert.deepEqual(body.why, { status: 200, bytes: empty.length },
  'a readable feed with no entries reports a clean 200');

res = await withFetch(async () => new Response('nope', { status: 429 }));
body = await res.json();
assert.equal(body.videoId, null, 'an upstream error reads as nothing to show');
assert.deepEqual(body.why, { status: 429 },
  'a non-200 is reported as the status it was, not as a quiet channel');

res = await withFetch(async () => { throw new Error('network'); });
body = await res.json();
assert.equal(body.videoId, null, 'a thrown fetch reads as nothing to show');
assert.match(body.why.error, /network/, 'a thrown fetch reports the throw');
console.log('ok: the endpoint answers JSON, stays cacheable, and says why it is empty');
