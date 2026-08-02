// GET /api/leaderboard?board=daily|monthly -- the boards, for the Twitch
// overlay to render.
//
// It is a read the stream pulls rather than a write the game pushes: the
// cluster tripbot runs in has no inbound path, deliberately, and a leaderboard
// is not a reason to open one. So the game keeps its scores where it already
// writes them and the bot fetches on its own schedule, which also degrades
// nicely -- the board being unreachable costs a rotation slot, nothing more.
import { lastClosedDate, monthOf } from '../../web/daily.js';

// The overlay renders five rows; ten leaves the bot room to filter or re-rank
// without a second request.
const ROWS = 10;

const json = (body, status = 200) =>
  new Response(JSON.stringify(body), {
    status,
    headers: {
      'content-type': 'application/json',
      // A board changes when a play lands, and the bot polls on its own timer.
      // A minute of cache costs nothing and stops a retry loop hammering D1.
      'cache-control': 'public, max-age=60',
    },
  });

// What renders for a play carrying no name -- one recorded before aliases
// existed, or from a browser that cannot keep localStorage and so cannot hold a
// place on a board anyway. The score still counts and still places, so a board
// is never short a row.
const PLACEHOLDER = 'anonymous';

// Both boards are the same shape over the same table: sum a player's points
// across a span of dates, best first. The span is the only difference, so it is
// the only thing that varies -- `date = ?` for a day, `date LIKE ?` for a month.
//
// The name is safe to render as stored because of where it comes from: it is
// drawn from a curated wordlist, so the review happens when the name is made
// rather than after it is typed. That is what removes the moderation queue this
// endpoint would otherwise have to consult -- there is nothing here a stranger
// chose. Should typed names ever land, the allowlist lands with them and joins
// in right here.
//
// ponytail: MAX picks alphabetically-last for a player who rerolled mid-span.
// Rerolling is a button in the About panel, the cost is a stale-but-safe label,
// and last-write-wins needs a correlated subquery over played_at.
const query = span => `
  SELECT p.player_id,
         SUM(p.points) AS points,
         MAX(p.handle) AS name
    FROM plays p
   WHERE p.date ${span}
   GROUP BY p.player_id
   ORDER BY points DESC, p.player_id
   LIMIT ?`;

export async function onRequestGet({ request, env }) {
  const board = new URL(request.url).searchParams.get('board') || 'daily';
  if (board !== 'daily' && board !== 'monthly') {
    return json({ error: 'board must be daily or monthly' }, 400);
  }

  // The daily board is the last *closed* date, never one still filling. The
  // monthly board is the current month, today included.
  const daily = board === 'daily';
  const period = daily ? lastClosedDate() : monthOf();
  const { results } = await env.ANSWERS
    .prepare(query(daily ? '= ?' : "LIKE ? || '-%'"))
    .bind(period, ROWS)
    .all();

  return json({
    board,
    period,
    rows: results.map(r => [r.name || PLACEHOLDER, r.points]),
  });
}
