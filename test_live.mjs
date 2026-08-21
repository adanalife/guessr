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
//
// `calls` is what the retry and the cache lifetime are actually about, so the
// stub counts as well as answers.
let calls = 0;
const withFetch = async (impl) => {
  const real = globalThis.fetch;
  calls = 0;
  globalThis.fetch = (...args) => { calls++; return impl(...args); };
  try { return await onRequestGet(); } finally { globalThis.fetch = real; }
};
const maxAge = res => Number(res.headers.get('cache-control').match(/max-age=(\d+)/)[1]);

let res = await withFetch(async () => new Response(live, { status: 200 }));
let body = await res.json();
assert.equal(body.videoId, 'Uhln8S-ZCMI');
assert.deepEqual(body.why, { status: 200, bytes: live.length });
assert.equal(calls, 1, 'a read that landed is not retried');
const LIVE_TTL = maxAge(res);
assert.ok(LIVE_TTL >= 60,
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
// A quiet channel is an answer, not a failure: the feed was read and said
// nothing is there, which will still be true in five minutes.
assert.equal(calls, 1, 'an empty feed is not retried -- it was read');
assert.equal(maxAge(res), LIVE_TTL, 'an empty feed is cached as long as a full one');

res = await withFetch(async () => new Response('nope', { status: 429 }));
body = await res.json();
assert.equal(body.videoId, null, 'an upstream error reads as nothing to show');
assert.deepEqual(body.why, { status: 429, attempts: 2 },
  'a non-200 is reported as the status it was, not as a quiet channel');
assert.equal(calls, 2, 'a read that never landed is attempted again');
// The regression this guards. Caching a failed read for the full window is what
// keeps the cell blank for everyone behind one unlucky request, long after the
// feed recovers -- YouTube serves this one unreliably enough for it to matter.
assert.ok(maxAge(res) < LIVE_TTL,
  'a failed read expires sooner than an answer, so the next player retries');

// The second attempt is a real one, so a feed that recovers between them is
// answered rather than reported as broken.
res = await withFetch(async () => calls === 1
  ? new Response('nope', { status: 500 })
  : new Response(live, { status: 200 }));
body = await res.json();
assert.equal(body.videoId, 'Uhln8S-ZCMI', 'a feed that recovers on the retry is answered');
assert.equal(maxAge(res), LIVE_TTL, 'and that answer is cached like any other');

res = await withFetch(async () => { throw new Error('network'); });
body = await res.json();
assert.equal(body.videoId, null, 'a thrown fetch reads as nothing to show');
assert.match(body.why.error, /network/, 'a thrown fetch reports the throw');
assert.equal(calls, 2, 'a thrown fetch is attempted again too');
console.log('ok: the endpoint answers JSON, retries a read that never landed, '
  + 'and caches a failure only briefly');
