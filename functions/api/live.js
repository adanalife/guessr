// GET /api/live -- the video id of the channel's current live broadcast, or null
// when it is dark.
//
// It exists because the end-of-game board wants to show the stream the footage
// comes from, and a live embed needs a video id that changes with every
// broadcast. The two obvious ways to get one both fail:
//
//   - `/embed/live_stream?channel=<id>` used to resolve it inside the player and
//     needed no server at all. It is retired: it answers "This video is
//     unavailable" for a channel that is demonstrably live.
//   - The YouTube Data API would answer it properly, but it needs a key, and a
//     key in a static page is a public key. Quota is already the binding
//     constraint on that API elsewhere in this project's fleet, and a 24/7
//     channel polled from every finished game is exactly the shape that spends
//     it.
//
// So this reads the channel's own /live permalink, which is public, keyless, and
// the same page a player would land on. One upstream request per TTL rather than
// per game: `cacheEverything` is what makes that true, since the page carries no
// cache headers of its own.
const LIVE_PERMALINK = 'https://www.youtube.com/@adanalife_/live';

// Two minutes. The answer only changes when a broadcast starts or ends, and
// being a couple of minutes stale about that costs a player nothing -- the
// caption's link is correct either way.
const TTL = 120;

// Both markers are required, and that is the whole correctness argument.
//
// A dark channel's /live does not 404: it canonicalises to the *channel* page
// and drops the live flags. A channel that has streamed before can also
// canonicalise to a past broadcast. So the canonical watch id alone would
// happily hand back a video that finished last week, which would embed fine and
// silently claim to be live. `isLiveNow` is what makes the id mean "now".
//
// Exported for test_live.mjs, which runs it over saved copies of a live page and
// a dark one rather than a second copy of the logic. Pages only looks for the
// onRequest* exports.
export function liveVideoId(html) {
  if (!html.includes('"isLiveNow":true')) return null;
  const m = html.match(/<link rel="canonical" href="https:\/\/www\.youtube\.com\/watch\?v=([\w-]{11})">/);
  return m ? m[1] : null;
}

export async function onRequestGet() {
  let videoId = null;
  try {
    const res = await fetch(LIVE_PERMALINK, {
      cf: { cacheTtl: TTL, cacheEverything: true },
    });
    if (res.ok) videoId = liveVideoId(await res.text());
  } catch {
    // Dark is the safe answer: it degrades the board to a link, where a thrown
    // error would degrade it to a console message and an empty cell.
  }
  return new Response(JSON.stringify({ videoId }), {
    headers: {
      'content-type': 'application/json',
      'cache-control': `public, max-age=${TTL}`,
    },
  });
}
