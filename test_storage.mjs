// Cover what the browser keeps between visits, and what happens when it can't.
//
// Worth testing because every function in storage.js swallows its own
// exception. That is the right call -- a Safari private window throws on
// storage rather than returning null, and a dismissed dialog is not worth
// failing a round over -- but it means a store that refuses is indistinguishable
// from one that is merely empty, in both directions: the fallback is silent when
// it works, and the throw it was written to swallow escapes into the caller when
// it doesn't. A page whose script dies on line one renders its markup and does
// nothing at all, which is the failure this file exists to catch.
//
// The private window is the case nobody develops in and CI never opens, so a
// store whose every method throws is the only place it gets looked at.

import assert from 'node:assert/strict';
import {
  MAX_HISTORY, loadHistory, markSeen, recordHistory, restoreTruths, saveDaily, savedDaily, seen,
} from './web/storage.js';

// A working store, in memory. Not a Map: the real one stringifies whatever it
// is handed and returns null for a key it does not hold, and both of those are
// behaviours the callers lean on.
const fakeStore = () => {
  const held = new Map();
  return {
    held,
    getItem: k => (held.has(k) ? held.get(k) : null),
    setItem: (k, v) => held.set(k, String(v)),
  };
};

// The private window: present, and throws on everything.
const refusing = {
  getItem() { throw new DOMException('The operation is insecure.', 'SecurityError'); },
  setItem() { throw new DOMException('The quota has been exceeded.', 'QuotaExceededError'); },
};

// A store that is there but full -- reads fine, refuses every write. Distinct
// from the one above because it is the case where a read confirms the write
// silently didn't happen.
const full = () => {
  const store = fakeStore();
  store.setItem = () => { throw new DOMException('exceeded', 'QuotaExceededError'); };
  return store;
};

// Every function, against a store that throws. None of them may throw, and each
// has to land on the fallback its caller was written against.
assert.equal(savedDaily(refusing), null, 'savedDaily must read as no game in progress');
assert.deepEqual(loadHistory(refusing), [], 'loadHistory must read as no history');
assert.doesNotThrow(() => saveDaily({ day: 1 }, refusing), 'saveDaily must not break the round');
assert.doesNotThrow(() => markSeen('guessr-about-seen', refusing), 'markSeen must not throw');
// seen() falls back to *true*, not false: a browser that cannot remember a
// dismissal would otherwise show the intro modal on every single page load.
assert.equal(seen('guessr-welcome-seen', refusing), true,
  'a store that refuses must read as already seen, or the intro reopens forever');
// recordHistory still has to answer with the count its caller uses, and the
// entry is in the list it returns even though nothing kept it.
assert.equal(recordHistory([1, 2, 3, 4, 5, true], refusing), 1,
  'recordHistory must still count the round it was handed');

// A store that reads but will not write: the write is lost, and nothing says so.
{
  const store = full();
  assert.doesNotThrow(() => saveDaily({ day: 9 }, store));
  assert.equal(savedDaily(store), null, 'a refused write must not appear to have landed');
  assert.equal(recordHistory([1, 1, 2, 2, 100, false], store), 1);
  assert.deepEqual(loadHistory(store), [], 'a refused write must leave the history empty');
}

// Garbage in the store is the other silent case: a half-written value, or a key
// left by an older shape of the game. JSON.parse throws on it, and the fallback
// has to be the same one an empty store gets.
{
  const store = fakeStore();
  store.setItem('guessr-daily', '{not json');
  store.setItem('guessr-history', '[[1,2,');
  assert.equal(savedDaily(store), null, 'unparseable daily state must read as none');
  assert.deepEqual(loadHistory(store), [], 'an unparseable history must read as empty');
  // And a stored `null` -- which is what JSON.stringify(null) leaves behind --
  // must not become the history itself.
  store.setItem('guessr-history', 'null');
  assert.deepEqual(loadHistory(store), [], 'a stored null must read as an empty history');
}

// The round trip the resume path depends on.
{
  const store = fakeStore();
  const state = {
    day: 42, results: [5000, 1200], total: 6200, guesses: [[1, 2], [3, 4]],
    truths: [{ lat: 1, lng: 2, state: 'Utah', filmed: '2019' }],
  };
  saveDaily(state, store);
  assert.deepEqual(savedDaily(store), state, 'a saved day did not come back as it went in');
  // What is stored is a string, not the object -- a store handed a live
  // reference would let a later mutation rewrite a finished day.
  assert.equal(typeof store.held.get('guessr-daily'), 'string');
  state.total = 99999;
  assert.equal(savedDaily(store).total, 6200, 'the saved day tracked a later mutation');
}

// An empty store is not an error, and must not read as one.
{
  const store = fakeStore();
  assert.equal(savedDaily(store), null);
  assert.deepEqual(loadHistory(store), []);
  assert.equal(seen('guessr-about-seen', store), false, 'a fresh browser has seen nothing');
  markSeen('guessr-about-seen', store);
  assert.equal(seen('guessr-about-seen', store), true, 'a dismissal did not stick');
  // Keys are independent: dismissing the intro must not count as having read
  // the About panel, which is where the stream and the bot are linked.
  assert.equal(seen('guessr-welcome-seen', store), false, 'the two dismissals share a key');
}

// restoreTruths is the pure one: it takes the answers off a saved day and puts
// them back on the rounds that were re-drawn without them.
{
  const rounds = [{ name: 'a' }, { name: 'b' }];
  restoreTruths(rounds, { truths: [{ lat: 1, lng: 2 }, { lat: 3, lng: 4 }] });
  assert.deepEqual(rounds, [{ name: 'a', lat: 1, lng: 2 }, { name: 'b', lat: 3, lng: 4 }]);

  // A save written before the answers moved server-side has no truths at all,
  // and neither does a browser with nothing saved. Both have to leave the
  // rounds alone rather than throwing on the way to the board.
  for (const saved of [null, undefined, {}, { truths: null }, { truths: [] }]) {
    const untouched = [{ name: 'a' }];
    assert.doesNotThrow(() => restoreTruths(untouched, saved), `restoreTruths threw on ${JSON.stringify(saved)}`);
    assert.deepEqual(untouched, [{ name: 'a' }], 'a save with no truths changed the rounds');
  }
  // More truths than rounds -- a shorter game replayed against a longer save --
  // must not invent a round to hang them on.
  const one = [{ name: 'a' }];
  restoreTruths(one, { truths: [{ lat: 1 }, { lat: 2 }, { lat: 3 }] });
  assert.equal(one.length, 1, 'restoreTruths grew the round list');
}

// The history trim. Unbounded, this is what fills a browser's storage quota and
// what turns the all-time map into a smear -- three Leaflet layers a round, so
// the cap is a rendering budget as much as a storage one.
{
  // Pinned, because the cap is a budget rather than a preference: it is what
  // keeps a long-running browser inside its storage quota and the all-time map
  // inside a few hundred Leaflet layers. Raising it is a decision, not a tweak.
  assert.equal(MAX_HISTORY, 250, 'the history cap moved');

  const store = fakeStore();
  // Past the cap by enough that an off-by-one in the slice shows up as one.
  for (let i = 0; i < MAX_HISTORY + 20; i++) recordHistory([0, 0, 0, 0, i, true], store);

  const rounds = loadHistory(store);
  assert.equal(rounds.length, MAX_HISTORY, `the history grew to ${rounds.length}`);
  // Newest kept, oldest dropped -- the wrong end would leave a returning player
  // looking at a map of rounds they played months ago and none of this week's.
  assert.equal(rounds.at(-1)[4], MAX_HISTORY + 19, 'the newest round is not last');
  assert.equal(rounds[0][4], 20, 'the trim dropped the wrong end');
  // Still in order, and one entry per round.
  assert.deepEqual(rounds.map(r => r[4]), rounds.map((_, i) => i + 20), 'the history lost its order');
  // The return value is what the caller reads to decide anything, so it has to
  // be the trimmed length rather than the count of rounds ever played.
  assert.equal(recordHistory([0, 0, 0, 0, 999, true], store), MAX_HISTORY,
    'recordHistory reported a length past the cap');
}

// Below the cap it is a plain append -- entries stay whole, in the order played.
{
  const store = fakeStore();
  const entries = [[1, 2, 3, 4, 5000, true], [5, 6, 7, 8, 0, false]];
  entries.forEach((e, i) => { assert.equal(recordHistory(e, store), i + 1); });
  assert.deepEqual(loadHistory(store), entries, 'the history is not what was recorded');
}

// The keys are a contract with the browsers already holding them: renaming one
// silently orphans every player's history, and the reset button clears by the
// `guessr-` prefix rather than by a list.
{
  const store = fakeStore();
  saveDaily({ day: 1 }, store);
  recordHistory([0, 0, 0, 0, 0, true], store);
  markSeen('guessr-about-seen', store);
  const keys = [...store.held.keys()];
  assert.deepEqual(keys.sort(), ['guessr-about-seen', 'guessr-daily', 'guessr-history']);
  assert.ok(keys.every(k => k.startsWith('guessr-')),
    'a key outside the guessr- prefix survives the reset button');
}

console.log('ok: every stored read and write degrades rather than throwing when storage refuses');
console.log('ok: a saved day round-trips, and unparseable state reads as none');
console.log(`ok: the history trims to ${MAX_HISTORY}, newest kept, in order`);
