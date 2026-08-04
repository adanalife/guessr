// Cover the live-stream resolver: which YouTube /live pages yield a video id.
//
// Worth testing because both failure directions are silent. Too strict and the
// end-of-game board never shows the stream even while it is running, and nothing
// anywhere says so -- the cell just stays a link. Too loose and it embeds a
// finished broadcast as though it were live, which looks completely normal and is
// a lie to every player who reaches that screen.
//
// The fixtures are the real markup, trimmed: a live channel's /live page and a
// dark one's. The shapes worth pinning are that a dark channel does not 404 (it
// canonicalises to the channel page and drops the live flags) and that the two
// markers have to agree -- a canonical watch id with no live flag is the past
// broadcast case, and that is the one this function exists to refuse.
import assert from 'node:assert/strict';
import { liveVideoId, onRequestGet } from './functions/api/live.js';

const CANONICAL = id => `<link rel="canonical" href="https://www.youtube.com/watch?v=${id}">`;
const CHANNEL_CANONICAL =
  '<link rel="canonical" href="https://www.youtube.com/channel/UC8Q7uFC1Xyr2ZnTWOk9Aizg">';
const page = (...parts) =>
  `<!DOCTYPE html><html><head><title>A Dana Life</title>${parts.join('')}</head><body></body></html>`;

const live = page(CANONICAL('Uhln8S-ZCMI'), '<script>var x = {"isLiveNow":true};</script>');
const dark = page(CHANNEL_CANONICAL, '<script>var x = {};</script>');
const endedBroadcast = page(CANONICAL('Uhln8S-ZCMI'), '<script>var x = {};</script>');

assert.equal(liveVideoId(live), 'Uhln8S-ZCMI', 'a live page yields its canonical video id');
assert.equal(liveVideoId(dark), null, 'a dark channel canonicalises to the channel, not a video');
assert.equal(liveVideoId(endedBroadcast), null,
  'a canonical video with no live flag is a past broadcast, not the stream');
assert.equal(liveVideoId(''), null, 'an empty body is dark rather than a throw');
// The id goes straight into an embed URL, so anything that is not exactly a
// YouTube id has to be refused rather than passed along.
assert.equal(liveVideoId(page('<link rel="canonical" href="https://www.youtube.com/watch?v=short">',
  '<script>{"isLiveNow":true}</script>')), null, 'an id of the wrong length is refused');
assert.equal(liveVideoId(page(
  '<link rel="canonical" href="https://evil.example/watch?v=Uhln8S-ZCMI">',
  '<script>{"isLiveNow":true}</script>')), null, 'a canonical on another host is refused');
console.log('ok: a live page yields an id, and a dark or finished one yields nothing');

// The endpoint's own contract: JSON, cached, and dark whenever the upstream read
// fails -- an exception here would leave the board with an empty sixth cell.
const withFetch = async (impl) => {
  const real = globalThis.fetch;
  globalThis.fetch = impl;
  try { return await onRequestGet(); } finally { globalThis.fetch = real; }
};

let res = await withFetch(async () => new Response(live, { status: 200 }));
let body = await res.json();
assert.equal(body.videoId, 'Uhln8S-ZCMI');
assert.deepEqual(body.why, { status: 200, bytes: live.length, liveFlag: true,
  canonical: 'https://www.youtube.com/watch?v=Uhln8S-ZCMI', title: 'A Dana Life' });
assert.match(res.headers.get('cache-control'), /^public, max-age=\d+$/,
  'the answer is cacheable, so one upstream read serves many finished games');

// Each failure is dark to the board and distinct in `why`, which is the whole
// point of carrying it: these three nulls need three different fixes.
res = await withFetch(async () => new Response(dark, { status: 200 }));
body = await res.json();
assert.equal(body.videoId, null);
assert.deepEqual(body.why, { status: 200, bytes: dark.length, liveFlag: false,
  canonical: 'https://www.youtube.com/channel/UC8Q7uFC1Xyr2ZnTWOk9Aizg', title: 'A Dana Life' },
  'a dark channel is a full 200 page canonicalising to the channel, not a video');

res = await withFetch(async () => new Response('nope', { status: 500 }));
body = await res.json();
assert.equal(body.videoId, null, 'an upstream error reads as dark');
assert.deepEqual(body.why, { status: 500 },
  'a non-200 is reported as the status it was, not as a dark channel');

res = await withFetch(async () => { throw new Error('network'); });
body = await res.json();
assert.equal(body.videoId, null, 'a thrown fetch reads as dark');
assert.match(body.why.error, /network/, 'a thrown fetch reports the throw');
console.log('ok: the endpoint answers JSON, stays cacheable, and treats every failure as dark');
