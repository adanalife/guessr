// When a day of this game happens: which calendar date a day number is, when
// that date is open to play, and which one a board can be final for. Kept out of
// index.html so it can be exercised by test_daily.mjs -- every rule here is a
// date arithmetic rule, and those fail quietly across DST and timezones rather
// than erroring.
//
// *Which rounds* a date plays is not here: that is a row set in D1, read through
// /api/day. What lives here is the half that is genuinely a rule rather than
// data -- the page and the scorer have to agree on when a date is open, or one
// accepts plays the other refuses.
//
// An ES module, imported by the page and by functions/api/{day,score}.js alike.
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

// When a date is open to play. Everyone gets until their own midnight, so a date
// runs from midnight in the earliest timezone on Earth (UTC+14, which is 10:00
// UTC the day before) to midnight in the latest (UTC-12, 12:00 UTC the day
// after). Up to three dates are therefore open at once.
//
// The close is what makes a board final. The open is what stops a player from
// running next week: /api/day refuses a date outside the window and /api/score
// refuses a play against one, so the lower bound is the whole of what keeps a
// future date's five out of reach.
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

// The most recent date whose board can no longer change -- what a board on the
// stream renders. Three dates are open at once, so "today" is not a single
// answer, and the alternative (show the streamer's own date, labelled
// in-progress) puts a board on screen that can still reorder while it is up.
// A board is worth broadcasting when it is final.
//
// Straight from the closing rule rather than by searching: date D closes at
// D+1 12:00 UTC, so the latest closed date is the UTC date 36 hours back --
// 12 to undo the close offset, 24 more to land on the date before it.
export function lastClosedDate(now = new Date()) {
  return new Date(now.getTime() - 36 * 3600 * 1000).toISOString().slice(0, 10);
}

// The month a monthly board covers, as the YYYY-MM prefix its dates share.
// Unlike the daily board this needs no closing rule -- it is a running total,
// and today's plays belong in it.
export function monthOf(now = new Date()) {
  return now.toISOString().slice(0, 7);
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
