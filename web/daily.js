// What a day of this game *is*: which rounds it draws, what order they come in,
// and when it is open to play. Kept out of index.html so it can be exercised by
// test_daily.mjs -- a non-deterministic daily draw fails invisibly (every player
// simply gets different rounds, nothing errors, and the share string quietly
// stops meaning anything), so it is the piece here that most needs a test.
//
// An ES module, and imported by both sides: the page draws a game from it, and
// functions/api/score.js verifies against it that a posted round really is one
// of that date's five. Those two answers have to be the same answer -- a server
// working from its own copy of the draw would reject legitimate plays the day
// the copies drifted, and nothing would say why. So there is one copy, here.
//
// Dependency-free, so `node test_daily.mjs` runs it with no bundler.

// Day 1. Everyone playing on the same calendar day draws the same five rounds,
// which is the whole point of a share string -- there is nothing to compare if
// each player gets different rounds.
const EPOCH = new Date(2026, 6, 31);

// How many rounds a game is. Exported because the server has to draw exactly the
// same five to check one -- drawing a different number would silently reject the
// tail of every game.
export const ROUNDS_PER_GAME = 5;

export function dayNumber(now = new Date()) {
  const midnight = new Date(now.getFullYear(), now.getMonth(), now.getDate());
  // Local rather than UTC, so the round turns over at the player's own
  // midnight. Math.round absorbs the hour DST adds or removes -- without it,
  // the spring-forward day is 23 hours and floor() would skip a day number.
  return Math.round((midnight - EPOCH) / 86400000) + 1;
}

// The inverse of dayNumber(): the calendar date a day number stands for, as
// YYYY-MM-DD. What a recorded play is keyed on, because a day number only means
// something relative to an epoch that could move, while a date is a date.
//
// Built by pushing the day count through the Date constructor's own overflow
// handling rather than adding milliseconds: 86400000 ms past a spring-forward
// midnight is 01:00, and past an autumn one is 23:00 of the day before, which
// formats as the wrong date twice a year.
export function dateForDay(day) {
  const d = new Date(EPOCH.getFullYear(), EPOCH.getMonth(), EPOCH.getDate() + day - 1);
  const pad = n => String(n).padStart(2, '0');
  return `${d.getFullYear()}-${pad(d.getMonth() + 1)}-${pad(d.getDate())}`;
}

// And back again, which is how the server turns a posted date into the draw to
// check it against.
//
// Both directions build local-midnight Dates and difference them, so the answer
// does not depend on which timezone is asking -- the page in Auckland and the
// worker in UTC have to agree on which five rounds "2026-08-01" means, or one
// rejects what the other drew.
export function dayFromDate(date) {
  const [y, m, d] = date.split('-').map(Number);
  return dayNumber(new Date(y, m - 1, d));
}

// When a date is open to play. Everyone gets until their own midnight, so a date
// runs from midnight in the earliest timezone on Earth (UTC+14, which is 10:00
// UTC the day before) to midnight in the latest (UTC-12, 12:00 UTC the day
// after). Up to three dates are therefore open at once.
//
// The close is what makes a board final. The open is what stops a player from
// running next week: the draw is deterministic and computed on the client, so
// without a lower bound anyone can work out and post a future date's five today.
const OPENS_UTC_HOUR = 10;
const CLOSES_UTC_HOUR = 12;

export function playWindow(date) {
  const [y, m, d] = date.split('-').map(Number);
  // Date.UTC normalises the day under- and overflow, so the first and last of a
  // month need no special case.
  return {
    opens: Date.UTC(y, m - 1, d - 1, OPENS_UTC_HOUR),
    closes: Date.UTC(y, m - 1, d + 1, CLOSES_UTC_HOUR),
  };
}

export function isOpen(date, now = new Date()) {
  const { opens, closes } = playWindow(date);
  const t = now.getTime();
  return t >= opens && t < closes;
}

// Seeded PRNG so the daily draw is reproducible from the date alone, with no
// server telling the client which rounds to play.
function mulberry32(seed) {
  return function () {
    seed |= 0; seed = seed + 0x6D2B79F5 | 0;
    let t = Math.imul(seed ^ seed >>> 15, 1 | seed);
    t = t + Math.imul(t ^ t >>> 7, 61 | t) ^ t;
    return ((t ^ t >>> 14) >>> 0) / 4294967296;
  };
}

function hashSeed(str) {
  let h = 2166136261;
  for (let i = 0; i < str.length; i++) { h ^= str.charCodeAt(i); h = Math.imul(h, 16777619); }
  return h >>> 0;
}

// Exported for the practice draw, which is the same shuffle-and-take over the
// whole pool with an unseeded source.
export function pick(pool, n, rand) {
  const a = [...pool];
  for (let i = a.length - 1; i > 0; i--) {
    const j = Math.floor(rand() * (i + 1));
    [a[i], a[j]] = [a[j], a[i]];
  }
  return a.slice(0, n);
}

export function dailyRounds(pool, day, n) {
  // Sorted first so the draw depends on which rounds exist, not on the order
  // make_rounds.py happened to write them in.
  const stable = [...pool].sort((a, b) => a.image.localeCompare(b.image));
  return pick(stable, n, mulberry32(hashSeed(`day-${day}`)));
}

// The day the page plays, which only ever moves forwards. dayNumber() reads the
// player's local calendar date, so anything that lowers it -- flying west across
// a timezone, a manual clock change, a device that comes back with the wrong
// date -- would otherwise re-open a day already played out. The stored record's
// day is the highest ever reached, so clamping to it is the whole gate; a day
// that has genuinely arrived is larger and passes straight through.
//
// Known ceiling: a clock set far into the future strands the player on that day
// even after it is corrected. Recovering means clearing saved state, which is
// the same answer as for any other corrupt record, and a wrong-future clock is
// rarer than the westward flight this exists for.
export function effectiveDay(saved, now = new Date()) {
  return Math.max(dayNumber(now), saved ? saved.day : 0);
}

// What a stored daily record means for the page. No record, or one from an
// earlier day, means today is unplayed; a same-day record holding every round is
// done; a shorter same-day one is a game to pick back up.
//
// Split out of index.html because getting it wrong is silent either way: reading
// a half-played day as finished hides the rest of the game, and reading a
// finished day as unplayed hands out a second run at the same five rounds.
export function dailyState(saved, day, roundsPerGame) {
  if (!saved || saved.day !== day) return 'unplayed';
  return saved.results.length >= roundsPerGame ? 'finished' : 'unfinished';
}

// Orders an already-drawn game easy to hard, by median_km -- the median
// distance from a frame's true location to that of its nearest neighbours in
// embedding space, so a low score means the image carries real location signal
// and a high one means the look is generic.
//
// It must run on the *selection*, never inside the draw: reordering the pool
// would change which rounds a day draws, and the share string only means
// something if every player gets the same five.
export function rampEasyToHard(rounds) {
  return [...rounds].sort((a, b) => a.median_km - b.median_km);
}

// Difficulty bands, in median_km. The two cutoffs are the terciles of the
// shipped round set, so the bands split the pool into roughly equal thirds
// (99 / 100 / 101 of 300 rounds).
export const EASY_KM = 32;
export const HARD_KM = 120;
export const DIFFICULTY_LEVELS = 3;

// 1 (easiest) to DIFFICULTY_LEVELS (hardest).
export function difficulty(round) {
  return round.median_km < EASY_KM ? 1 : round.median_km < HARD_KM ? 2 : 3;
}
