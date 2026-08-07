// The share string, and the score bands it is drawn from.
//
// Out of index.html for the reason daily.js and alias.js are: it is pure, and it
// fails silently. Nothing about a wrong share string throws -- the squares still
// render, the totals still add up, the paste still works -- so the only way to
// notice is for someone to look at one and know what it should have said.
//
// It is also the piece with the most riding on it. A shared result is how anyone
// who does not already watch the stream arrives at the game, so the string is
// the whole top of the funnel: the squares are what make it worth pasting and
// HOME_URL is the only thing in it that leads anywhere.
//
// Dependency-free, so `node test_share.mjs` runs it with no bundler.

// Only the share line's denominator. The scoring itself is server-side, and
// functions/_scoring.mjs owns the real value -- a round reaches the browser as a
// name and nothing else, so there is nothing here to score with.
export const MAX_ROUND_SCORE = 5000;

// The share string is pasted where the link outlives the session that made it,
// so it names the canonical host rather than wherever this copy is served from
// -- a result shared off localhost or a preview deploy still sends people here.
export const HOME_URL = 'https://guessr.dana.lol';

// Score bands, ordered best first. One table so a round's square in the share
// string and its line on the end-of-game map are always the same colour.
//
// Order is load-bearing: bandFor takes the first band a score clears, so a table
// sorted any other way hands every round the same square and says nothing.
//
// 4989 is `scoreFor(1)` — a guess within a kilometre of the truth. It reads as
// an arbitrary number because it is a distance wearing the units the share
// string happens to speak; the curve is invertible, so a round bar in points
// would have been a ragged one in km, which is the thing a player experiences.
//
// A kilometre and not a rounder five: across 226 recorded guesses, 2.7% land
// inside 1 km against 5.3% inside 5 km, so the tighter bar shows up in roughly
// one game in eight. Rare enough to be worth pasting, common enough to exist.
// Re-derive it from `plays` rather than adjusting by feel if it stops landing
// there — `stats.sql` holds the km of every guess ever made.
//
// The trophy takes the square rather than sitting beside it: a share line is
// read at a glance, and one round widening to two symbols costs the row the
// alignment that makes it readable at all.
export const BANDS = [
  // Violet rather than a deeper green. The rest of the table is a gradient
  // (green good, grey bad) and a fifth green would have to be read against its
  // neighbour to mean anything; off the gradient entirely, it means "not on
  // this scale" at a glance, on a map tile as well as in a paste.
  { min: 4989, square: '🏆', colour: '#c084fc' },
  { min: 4000, square: '🟩', colour: '#4ade80' },
  { min: 2500, square: '🟨', colour: '#facc15' },
  { min: 1000, square: '🟧', colour: '#fb923c' },
  { min: 0, square: '⬜', colour: '#9ca3af' },
];

export const bandFor = pts => BANDS.find(b => pts >= b.min);
export const squareFor = pts => bandFor(pts).square;

// What a player pastes. Four lines: which day, how each round went, the total,
// and where to play it.
export function shareText(day, res, sum) {
  return [
    `Guessr #${day}`,
    res.map(squareFor).join(''),
    `${sum.toLocaleString()} / ${(res.length * MAX_ROUND_SCORE).toLocaleString()}`,
    HOME_URL,
  ].join('\n');
}

// The same thing on the page, where the squares can be styled rather than pasted.
export function scoreLine(res, sum) {
  return `<span class="squares">${res.map(squareFor).join('')}</span>
    <b>${sum.toLocaleString()}</b> / ${(res.length * MAX_ROUND_SCORE).toLocaleString()}`;
}
