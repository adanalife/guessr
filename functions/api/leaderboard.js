// GET /api/leaderboard?board=daily|monthly -- the boards, for the Twitch
// overlay to render.
//
// It is a read the stream pulls rather than a write the game pushes: the
// cluster tripbot runs in has no inbound path, deliberately, and a leaderboard
// is not a reason to open one. So the game keeps its scores where it already
// writes them and the bot fetches on its own schedule, which also degrades
// nicely -- the board being unreachable costs a rotation slot, nothing more.
import { lastClosedDate, monthOf } from '../../web/daily.js';
import { json } from '../_json.mjs';

// The overlay renders five rows; ten leaves the bot room to filter or re-rank
// without a second request.
const ROWS = 10;

// A board changes when a play lands, and the bot polls on its own timer. A
// minute of cache costs nothing and stops a retry loop hammering D1.
const CACHE = { 'cache-control': 'public, max-age=60' };

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
// The subquery below runs once per board row and seeks on player_id alone, which
// is what the `plays_by_player_recent` index exists to serve. Without that
// index each of those seeks is a full table scan, and since the overlay polls
// both boards continuously that reads millions of rows a day out of a table
// holding a few hundred. The results are identical either way, so
// test_leaderboard.mjs asserts the plan rather than the rows.
//
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

// Number the players who turn up wearing the same name, so the overlay does not
// read as one person listed twice.
//
// It happens by design: a name is two random picks from a 2,401-pair wordlist,
// made in the browser with no knowledge of who else is playing, so there is
// nothing at the point of generation that could avoid a clash. A day with fifty
// players is roughly a coin flip for at least one pair. Their scores are right
// either way -- `player_id` is what ranks them, and the name is only a label.
//
// Numbered here rather than stored numbered, because the clash belongs to a
// rendered board and not to a play: who a player collides with depends on who
// else placed that day, so a discriminator written into `plays` would outlive
// the collision that produced it and follow that player onto boards where they
// are the only one wearing the name.
//
// Every member of a colliding set is numbered, the first included: a lone
// "Amber Basin (2)" with no (1) above it reads as a board that dropped a row.
// Numbering follows board order, so the higher score takes (1).
//
// The placeholder is numbered on the same terms. Several nameless players are
// still several players, and exempting them would mean a board that renders
// "anonymous" twice with nothing to tell them apart.
export function label(names) {
  const totals = new Map();
  for (const name of names) totals.set(name, (totals.get(name) || 0) + 1);

  const seen = new Map();
  return names.map(name => {
    if (totals.get(name) === 1) return name;
    const nth = (seen.get(name) || 0) + 1;
    seen.set(name, nth);
    return `${name} (${nth})`;
  });
}

export async function onRequestGet({ request, env }) {
  const board = new URL(request.url).searchParams.get('board') || 'daily';
  if (board !== 'daily' && board !== 'monthly') {
    return json({ error: 'board must be daily or monthly' }, 400, CACHE);
  }

  // The daily board is the last *closed* date, never one still filling. The
  // monthly board is the current month, today included.
  const daily = board === 'daily';
  const period = daily ? lastClosedDate() : monthOf();
  const { results } = await env.ANSWERS
    .prepare(query(daily ? '= ?' : "LIKE ? || '-%'"))
    .bind(period, ROWS)
    .all();

  // The placeholder goes on before the numbering, so nameless players are
  // numbered against each other rather than left as several identical rows.
  const names = label(results.map(r => r.name || PLACEHOLDER));
  return json({
    board,
    period,
    rows: results.map((r, i) => [names[i], r.points]),
  }, 200, CACHE);
}
