// GET /api/live -- the video id to show for the channel's stream, or null.
//
// The end-of-game board wants to play the stream the footage comes from, and the
// only embed form that plays is `/embed/<videoId>`: the channel-resolving
// `/embed/live_stream?channel=<id>` renders YouTube error 153 in a real iframe
// even against a live channel, on youtube.com and youtube-nocookie.com alike.
// So a video id has to come from somewhere, and it has to keep arriving on its
// own -- a hardcoded one is wrong the moment a broadcast restarts.
//
// This reads the channel's Atom feed. It is keyless, costs no Data API quota,
// and its newest entry is the newest video on the channel, which for a live
// broadcast is that broadcast. Two things ruled out first:
//
//   - Scraping the /live permalink cannot work from here. YouTube does not
//     resolve that route server-side for a datacenter caller: it answers 200
//     with a ~1.1 MB app shell that has resolved no entity at all -- empty
//     `<title>`, `canonical="undefined"`, no live flag -- whatever headers are
//     sent. The feed is a machine-facing endpoint and answers properly.
//   - The Data API answers this exactly, but `search.list` costs 100 units a
//     call against a quota that is already the binding constraint in this fleet,
//     and the key would be one more secret to hold.
//
// The browser cannot read the feed itself -- YouTube serves it without CORS
// headers -- which is why this endpoint exists at all rather than the page
// fetching it directly.
import { json } from '../_json.mjs';

const FEED = 'https://www.youtube.com/feeds/videos.xml?channel_id=UC8Q7uFC1Xyr2ZnTWOk9Aizg';

// Five minutes. The answer changes only when a broadcast starts, and the feed is
// the same bytes for every player, so one upstream read serves every finished
// game in the window. `cacheEverything` is what makes that true, since the feed
// carries no cache headers worth honouring.
const TTL = 300;

// The feed is Atom and its entries are newest-first, so the first id is the
// newest video. Matching the one element wanted rather than parsing the document
// keeps a channel or video title that happens to contain markup from mattering.
//
// This does NOT prove the broadcast is live, which is a choice: there is no
// keyless liveness signal, and the graceful thing happens anyway. A YouTube live
// stream keeps its id after it ends, so a quiet channel embeds the replay of the
// last drive rather than an error panel, and the caption underneath is a link to
// the live page either way -- nothing on screen claims the player is live.
//
// Exported for test_live.mjs. Pages only looks for the onRequest* exports.
export function newestVideoId(xml) {
  return xml.match(/<yt:videoId>([\w-]{11})<\/yt:videoId>/)?.[1] ?? null;
}

export async function onRequestGet() {
  let videoId = null;
  // Why a null is null. Without it the board silently keeps its link, and a
  // resolver that can never resolve anything reads exactly like one whose
  // channel is quiet -- so a permanently broken resolver ships green.
  const why = {};
  try {
    const res = await fetch(FEED, { cf: { cacheTtl: TTL, cacheEverything: true } });
    why.status = res.status;
    if (res.ok) {
      const xml = await res.text();
      why.bytes = xml.length;
      videoId = newestVideoId(xml);
    }
  } catch (e) {
    // A link is the safe answer: it degrades the board to the caption it already
    // carries, where a throw would degrade it to an empty cell.
    why.error = String(e);
  }
  return json({ videoId, why }, 200, { 'cache-control': `public, max-age=${TTL}` });
}
