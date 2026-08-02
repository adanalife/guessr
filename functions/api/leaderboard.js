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
// Which name: the last one that player recorded anywhere, rather than the last
// one inside this span. A handle is a label and not an identity, so rerolling
// renames a player's whole history at once -- and scoped to the span instead, a
// name changed after a day had closed could never reach that day's board, which
// is the board the overlay shows most. Nothing is lost by renaming backwards,
// because `player_id` is what ranks a player and the label rides beside it.
//
// A reroll lands on the boards from that player's next recorded round: a handle
// only reaches this table on the back of a play, and no endpoint sets one alone.
//
// `handle IS NOT NULL` because a play can be nameless -- from a browser that
// refuses localStorage, or carrying a name the wordlist could not have made,
// which parsePlay drops. Without it, one such play would blank a name the player
// still has on every other row.
//
// ponytail: the subquery seeks per board row and there is no index on
// player_id alone, so it scans. Ten scans of days x players x 5 rows, behind a
// 60s cache; add `(player_id, played_at)` to schema.sql if a profile says so.
// Exported for test_leaderboard.mjs, which runs it against a real SQLite rather
// than a second copy of it. Pages only looks for the onRequest* exports.
export const query = span => `
  SELECT p.player_id,
         SUM(p.points) AS points,
         (SELECT h.handle
            FROM plays h
           WHERE h.player_id = p.player_id AND h.handle IS NOT NULL
           -- played_at is second-resolution, so two rounds committed inside one
           -- second tie; rowid breaks it by insert order.
           ORDER BY h.played_at DESC, h.rowid DESC
           LIMIT 1) AS name
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
