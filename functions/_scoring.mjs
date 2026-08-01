// Turning a guess into points. This is the whole reason the game has a backend:
// web/rounds.json used to ship every round's true coordinates to the browser, so
// any score could be read straight out of devtools -- or forged -- in seconds. A
// leaderboard built on that would rank whoever cared least.
//
// Underscore-prefixed, so Pages leaves it out of the routing table and
// functions/api/ can import it. Dependency-free ESM, so `node test_score.mjs`
// exercises it directly with no bundler and no package.json.

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
