// GET /api/leaderboard?board=daily|monthly[&date=YYYY-MM-DD] -- the boards, for
// the Twitch overlay to render.
//
// It is a read the stream pulls rather than a write the game pushes: the
// cluster tripbot runs in has no inbound path, deliberately, and a leaderboard
// is not a reason to open one. So the game keeps its scores where it already
// writes them and the bot fetches on its own schedule, which also degrades
// nicely -- the board being unreachable costs a rotation slot, nothing more.
import { lastClosedDate, monthOf } from '../../web/daily.js';
import { DATE, json } from '../_json.mjs';
import { nameExpr, PLACEHOLDER } from '../_names.mjs';

// The overlay renders five rows; ten leaves the bot room to filter or re-rank
// without a second request. Also the deepest rank guesses.js will resolve,
// since a rank below the board names nobody.
export const ROWS = 10;

// A board changes when a play lands, and the bot polls on its own timer. A
// minute of cache costs nothing and stops a retry loop hammering D1.
//
// Exported for guesses.js, which serves the same spans on the same terms.
export const CACHE = { 'cache-control': 'public, max-age=60' };

// A board asked for by date is a board that closed, and a closed board can
// never change again -- so it is worth an hour where a live one gets a minute.
export const DATED_CACHE = { 'cache-control': 'public, max-age=3600' };

// Which span a request asks for, as `{ period, cache }` -- or `{ error }` for
// one no board can serve. Shared with guesses.js so a drilldown resolves its
// rank against exactly the board the caller is looking at; the two disagreeing
// would name a different player than the row that was clicked.
//
// The default is the current board: the last closed date for the daily one, the
// running month for the monthly one. `date` names a specific closed date
// instead, and only on the daily board -- a month is a running total, and a
// single date against it names no span it could sum.
//
// A date at or past the close is refused rather than served, because the
// closing rule is the whole reason a board can be broadcast: an open date's
// standings reorder while they are on screen, and its pins are a public copy of
// roughly where today's answers are. Refusing is also the only way a caller can
// tell "that day is not finished" from "nobody played that day" -- the latter is
// a closed date with an empty `rows`, which is an answer rather than an error.
export function span(board, params) {
  const date = params.get('date');
  if (date === null) {
    return { period: board === 'daily' ? lastClosedDate() : monthOf(), cache: CACHE };
  }
  if (board !== 'daily') return { error: 'date applies to the daily board only' };
  // DATE is a shape test -- it matches the 31st of February, which the parser
  // then rolls forward into March rather than rejecting. Round-tripping is what
  // catches that: a date that formats back as itself is one the calendar has.
  const parsed = new Date(`${date}T00:00:00Z`);
  const real = !Number.isNaN(parsed.getTime())
    && parsed.toISOString().slice(0, 10) === date;
  if (!DATE.test(date) || !real) return { error: 'date must be YYYY-MM-DD' };
  if (date > lastClosedDate()) return { error: 'date has not closed yet' };
  return { period: date, cache: DATED_CACHE };
}

// Both boards are the same shape over the same table: sum a player's points
// across a span of dates, best first. The span is the only difference, so it is
// the only thing that varies -- `date = ?` for a day, `date LIKE ?` for a month.
//
// A player's own name is safe to render as stored because of where it comes
// from: it is drawn from a curated wordlist, so the review happens when the name
// is made rather than after it is typed. That is what removes the moderation
// queue this endpoint would otherwise have to consult -- there is nothing here a
// stranger chose. An operator alias is not from that list and does not need to
// be: whoever set it is the person the queue would have reported to.
//
// Which of a player's own names: the last one they recorded anywhere, rather
// than the last one inside this span. A handle is a label and not an identity, so rerolling
// renames a player's whole history at once -- and scoped to the span instead, a
// name changed after a day had closed could never reach that day's board, which
// is the board the overlay shows most. Nothing is lost by renaming backwards,
// because `player_id` is what ranks a player and the label rides beside it.
//
// A reroll lands on the boards from that player's next recorded round: a handle
// only reaches this table on the back of a play, and no endpoint sets one alone.
// An alias lands at once, being a row of its own rather than a field on a play.
//
// The name expression runs once per board row and both of its lookups are seeks
// -- `players` by its primary key, `plays` by `plays_by_player_recent`. Without
// that second index each of those seeks is a full table scan, and since the
// overlay polls both boards continuously that reads millions of rows a day out
// of a table holding a few hundred. The results are identical either way, so
// test_leaderboard.mjs asserts the plan rather than the rows.
//
// Exported for test_leaderboard.mjs, which runs it against a real SQLite rather
// than a second copy of it. Pages only looks for the onRequest* exports.
export const query = span => `
  SELECT p.player_id,
         SUM(p.points) AS points,
         ${nameExpr('p.player_id')} AS name
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
  const params = new URL(request.url).searchParams;
  const board = params.get('board') || 'daily';
  if (board !== 'daily' && board !== 'monthly') {
    return json({ error: 'board must be daily or monthly' }, 400, CACHE);
  }

  // The daily board is a closed date, never one still filling -- the last one
  // by default, or the one asked for. The monthly board is the current month,
  // today included.
  const daily = board === 'daily';
  const { period, cache, error } = span(board, params);
  if (error) return json({ error }, 400, CACHE);

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
  }, 200, cache);
}
