// Turning a guess into points. This is the whole reason the game has a backend:
// web/rounds.json used to ship every round's true coordinates to the browser, so
// any score could be read straight out of devtools -- or forged -- in seconds. A
// leaderboard built on that would rank whoever cared least.
//
// Underscore-prefixed, so Pages leaves it out of the routing table and
// functions/api/ can import it. Its one import is the alias wordlist, which is
// data rather than a dependency, so `node test_score.mjs` still exercises this
// directly with no bundler and no package.json.
import { isAlias } from '../web/alias.js';

// GeoGuessr's curve: full marks near-exact, ~0 across the continent. 4500 km is
// roughly the width of the playable area (the lower 48).
export const MAP_SIZE_KM = 4500;
export const MAX_ROUND_SCORE = 5000;

export function haversineKm(a, b) {
  const R = 6371, rad = d => d * Math.PI / 180;
  const dLat = rad(b.lat - a.lat), dLng = rad(b.lng - a.lng);
  const h = Math.sin(dLat / 2) ** 2 +
            Math.cos(rad(a.lat)) * Math.cos(rad(b.lat)) * Math.sin(dLng / 2) ** 2;
  return 2 * R * Math.asin(Math.sqrt(h));
}

export const scoreFor = km => Math.round(MAX_ROUND_SCORE * Math.exp(-10 * km / MAP_SIZE_KM));

// The one place untrusted input enters the game, so it rejects rather than
// coerces: `lat: "40"` or `lat: null` both become NaN in haversineKm, and NaN
// propagates to a 5000-point score. Bounds-checked as well as typed, because a
// guess at lat 900 is not a guess.
export function parseGuess(body) {
  if (!body || typeof body !== 'object') return null;
  const { image, lat, lng } = body;
  if (typeof image !== 'string' || !image || image.length > 200) return null;
  if (!Number.isFinite(lat) || lat < -90 || lat > 90) return null;
  if (!Number.isFinite(lng) || lng < -180 || lng > 180) return null;
  return { image, lat, lng };
}

// A guess carries a play context when it is part of a daily; a practice round
// sends none and is scored without being recorded. `date` is what marks the
// difference, so isPlay() and parsePlay() are kept apart: a body that means to
// be recorded but is malformed has to be a 400, not a silent non-record. A
// player whose score quietly never reaches the board has no way to notice.
export const isPlay = body => !!body && typeof body === 'object' && body.date !== undefined;

// The date is the calendar date of the round set being played, YYYY-MM-DD, and
// it keys the leaderboard directly -- day numbers are display only, so that a
// re-epoch or an off-by-one can never silently re-map history.
const DATE_RE = /^\d{4}-\d{2}-\d{2}$/;

// The handle is a display label, never an identity: two players called "Jason"
// are two rows keyed on different player_ids that happen to render the same
// string. Keying on the handle instead would read the second Jason's play as a
// replay of the first's and drop it.
export const MAX_HANDLE = 24;

export function parsePlay(body) {
  if (!isPlay(body)) return null;
  const { date, player_id: playerId, handle } = body;
  if (typeof date !== 'string' || !DATE_RE.test(date)) return null;
  // A regex-shaped date can still be the 31st of February; Date is the cheapest
  // real calendar. Month 13 and day 32 come back as an Invalid Date, but Feb 31
  // silently rolls forward to Mar 3, so both the NaN check and the round-trip
  // are load-bearing -- and toISOString() throws on an Invalid Date, so the NaN
  // check has to come first.
  const parsed = new Date(`${date}T00:00:00Z`);
  if (Number.isNaN(parsed.getTime())) return null;
  if (parsed.toISOString().slice(0, 10) !== date) return null;
  // Opaque and client-minted, so its only real constraints are that it is a
  // bounded string and that it is the same one next time. UUIDs are what the
  // page mints; anything longer is not one.
  if (typeof playerId !== 'string' || !playerId || playerId.length > 64) return null;
  // Absent is legal -- a play still belongs on the board without a name, and a
  // browser that cannot keep localStorage cannot keep an alias either.
  if (handle !== undefined && handle !== null && typeof handle !== 'string') return null;
  const label = (handle || '').trim();

  // A name the wordlist could not have produced is dropped rather than stored,
  // which is what makes that list a boundary rather than a client-side
  // convention: /api/score is reachable directly, so without this anyone can put
  // an arbitrary string on a board that renders to a live broadcast.
  //
  // Dropped, not rejected: the score itself was earned under checks that already
  // passed, so refusing the whole play would punish a legitimate guess for a
  // label. It records nameless and shows as the placeholder, which is also how a
  // player keeps their rank if a word is ever retired from the lists.
  return { date, playerId, handle: isAlias(label) ? label : null };
}
