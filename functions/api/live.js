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

// Five minutes for an answer, and half a minute for a failure to reach one.
//
// The feed is the same bytes for every player and changes only when a broadcast
// starts, so one read serves every game finished in the window. It offers 900
// seconds of its own, which is three times longer than a player should have to
// wait to see a stream that has just gone up -- hence a number here at all, and
// hence `cacheEverything`, which is what lets one be set.
//
// That reasoning inverts on a bad read. YouTube serves this feed unreliably --
// four identical requests seconds apart answered 404, 500, 500, 200 -- and a
// five-minute cache over one of those failures is a board with nothing in its
// sixth cell for every player behind it, long after the feed came back. A
// failure is not an answer, so it is not cached like one.
const TTL = 300, RETRY_TTL = 30;

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

// One attempt at the feed. `why.bytes` is the flag for whether the body was ever
// read: set on a 2xx and on nothing else, so it separates "the channel has
// nothing to show" from "the read did not land", which is the distinction both
// the retry and the cache lifetime turn on.
async function readFeed() {
  // Why a null is null. Without it the board silently keeps its link, and a
  // resolver that can never resolve anything reads exactly like one whose
  // channel is quiet -- so a permanently broken resolver ships green.
  const why = {};
  try {
    const res = await fetch(FEED, {
      cf: {
        cacheEverything: true,
        // Per status, not one number for all of them: `cacheTtl` would put a
        // transient 404 in Cloudflare's cache for the whole window, where a
        // retry -- this request's or the next player's -- reads the same
        // failure back rather than asking YouTube again.
        //
        // Safe to lose. Where this property is not honoured, `cacheEverything`
        // falls back to the feed's own headers, and those cache a success for
        // longer than asked and an error not at all -- slower to notice a new
        // broadcast, never a pinned failure.
        cacheTtlByStatus: { '200-299': TTL, '300-599': 0 },
      },
    });
    why.status = res.status;
    if (res.ok) {
      const xml = await res.text();
      why.bytes = xml.length;
      return { videoId: newestVideoId(xml), why };
    }
  } catch (e) {
    // A link is the safe answer: it degrades the board to the caption it already
    // carries, where a throw would degrade it to an empty cell.
    why.error = String(e);
  }
  return { videoId: null, why };
}

export async function onRequestGet() {
  // Twice, but only when the first read never landed: at this feed's failure
  // rate a single attempt is the difference between a board that usually shows
  // the stream and one that often does not. A second attempt is free on the path
  // that already worked, and it is a real attempt rather than the same cached
  // failure read again, because errors are no longer cached.
  //
  // Not a third. The point is to survive one bad roll, and a player waiting on
  // the sixth cell of a contact sheet should not wait on a chain of timeouts.
  let attempt = await readFeed();
  if (attempt.why.bytes === undefined) {
    attempt = await readFeed();
    // So that a `why` reporting one status is not read as one request having
    // been made. The status is the second attempt's; whether the first differed
    // is not worth a second shape in here.
    attempt.why.attempts = 2;
  }

  const { videoId, why } = attempt;
  return json({ videoId, why }, 200, {
    'cache-control': `public, max-age=${why.bytes === undefined ? RETRY_TTL : TTL}`,
  });
}
