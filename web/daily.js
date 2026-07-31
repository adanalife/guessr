// Daily-round selection. Kept out of index.html so it can be exercised by
// test_daily.js -- a non-deterministic daily draw fails invisibly (every player
// simply gets different rounds, nothing errors, and the share string quietly
// stops meaning anything), so it is the one piece here that needs a test.
//
// Plain script, no module system: the browser loads it with <script src> and
// the test evals it, both of which just want these names as globals.

// Day 1. Everyone playing on the same calendar day draws the same five rounds,
// which is the whole point of a share string -- there is nothing to compare if
// each player gets different rounds.
const EPOCH = new Date(2026, 6, 31);

function dayNumber(now = new Date()) {
  const midnight = new Date(now.getFullYear(), now.getMonth(), now.getDate());
  // Local rather than UTC, so the round turns over at the player's own
  // midnight. Math.round absorbs the hour DST adds or removes -- without it,
  // the spring-forward day is 23 hours and floor() would skip a day number.
  return Math.round((midnight - EPOCH) / 86400000) + 1;
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

function pick(pool, n, rand) {
  const a = [...pool];
  for (let i = a.length - 1; i > 0; i--) {
    const j = Math.floor(rand() * (i + 1));
    [a[i], a[j]] = [a[j], a[i]];
  }
  return a.slice(0, n);
}

function dailyRounds(pool, day, n) {
  // Sorted first so the draw depends on which rounds exist, not on the order
  // make_rounds.py happened to write them in.
  const stable = [...pool].sort((a, b) => a.image.localeCompare(b.image));
  return pick(stable, n, mulberry32(hashSeed(`day-${day}`)));
}
