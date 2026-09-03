// Everything the game keeps in the browser between visits: the day in progress,
// the all-time history behind the map, and the two once-per-browser dismissals.
//
// Out of index.html for the reason daily.js and share.js are, but with a sharper
// edge on it: every function here swallows the exception it might raise. A
// Safari private window throws rather than returning null, and none of this is
// worth failing a round over -- so each one has a documented fallback and no way
// to announce that it took it. That design is only correct if it actually
// degrades instead of throwing, which is exactly what a browser nobody tests in
// would be the first to find out.
//
// Dependency-free, so `node test_storage.mjs` runs it with no bundler.
//
// Every function takes the store as an optional argument, and reads the real one
// *inside* its try when none is passed. The lookup has to be in there: a browser
// with storage disabled can throw on the `localStorage` property access itself,
// not only on getItem, so a reference captured at import time would throw where
// nothing is catching -- which is the whole page, rather than one dismissed
// dialog.

// Records the day you last finished, so today's round can't be replayed for a
// better share string. The daily draw itself lives in daily.js.
const STORE_KEY = 'guessr-daily';
// Every round ever played, oldest first, for the all-time map. Each entry is
// [guessLat, guessLng, truthLat, truthLng, points, wasDaily] — an array rather
// than an object because there are hundreds of them and the keys would be most
// of the bytes.
const HISTORY_KEY = 'guessr-history';
// Oldest rounds fall off past this. It bounds three things at once: what
// localStorage holds, how many Leaflet layers the all-time map creates (three
// per round), and how legible the result is — past a few hundred lines the map
// is a smear rather than a record.
export const MAX_HISTORY = 250;

export function savedDaily(store) {
  try { return JSON.parse((store || localStorage).getItem(STORE_KEY) || 'null'); }
  catch { return null; }
}

// Written after every reveal rather than only at the end, so a reload mid-game
// resumes. Saving only the finished game let a player abandon a bad run, reload
// into a fresh copy of the same five rounds, and replay them knowing the answers.
export function saveDaily(state, store) {
  // The day plays through; it just won't survive a reload.
  try { (store || localStorage).setItem(STORE_KEY, JSON.stringify(state)); } catch { /* skip */ }
}

// A save written before the answers moved server-side has no truths in it, and
// they can't be recovered without re-scoring — those rounds simply sit out of
// the board and the sheet caption. It self-corrects at the next daily.
export function restoreTruths(rounds, saved) {
  (saved?.truths || []).forEach((t, i) => { if (rounds[i]) Object.assign(rounds[i], t); });
}

export function loadHistory(store) {
  try {
    return JSON.parse((store || localStorage).getItem(HISTORY_KEY)) || [];
  } catch {
    return [];
  }
}

export function recordHistory(entry, store) {
  const rounds = [...loadHistory(store), entry].slice(-MAX_HISTORY);
  // A full or disabled localStorage must not break the round in progress; the
  // all-time map is the only thing that suffers.
  try { (store || localStorage).setItem(HISTORY_KEY, JSON.stringify(rounds)); } catch { /* skip */ }
  return rounds.length;
}

// The once-per-browser dismissals. A store that refuses reads as already seen,
// so a private window gets no dot and no intro it has no way to remember
// dismissing.
export function seen(key, store) {
  try { return !!(store || localStorage).getItem(key); } catch { return true; }
}
export function markSeen(key, store) {
  try { (store || localStorage).setItem(key, '1'); } catch { /* nothing to remember */ }
}
