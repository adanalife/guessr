// Checks the generated leaderboard aliases. Run with `node test_alias.mjs`
// (or `task test`).
//
// The wordlists are the moderation boundary -- there is no review queue because
// nothing a player can produce needs reviewing -- so the checks that matter are
// about what the lists can generate, not about the picking.
import assert from 'node:assert';

import { MAX_HANDLE } from './functions/_scoring.mjs';
import { ADJECTIVES, ALIAS_COUNT, aliasFrom, NOUNS } from './web/alias.js';

// Every alias the lists can produce has to survive the server intact, and
// MAX_HANDLE is the column the board reads from. A word added later that pushed
// a pair over it would not fail anywhere obvious -- the play would simply record
// nameless and the player would show as the placeholder, having done nothing
// wrong. Exhaustive rather than sampled: it is 2,401 pairs and the whole point
// is that no combination is a surprise.
let longest = '';
for (const adjective of ADJECTIVES) {
  for (const noun of NOUNS) {
    const alias = `${adjective} ${noun}`;
    if (alias.length > longest.length) longest = alias;
  }
}
assert.ok(
  longest.length <= MAX_HANDLE,
  `"${longest}" is ${longest.length} chars; the board's column holds ${MAX_HANDLE}`,
);

// A duplicate is invisible in play -- it just makes one word twice as likely as
// the rest -- so nothing else would catch it.
for (const [name, list] of [['ADJECTIVES', ADJECTIVES], ['NOUNS', NOUNS]]) {
  assert.strictEqual(new Set(list).size, list.length, `${name} has a duplicate`);
  for (const word of list) {
    assert.match(word, /^[A-Z][a-z]+$/, `${name} entry ${JSON.stringify(word)} is not a plain capitalised word`);
  }
}

assert.strictEqual(ALIAS_COUNT, ADJECTIVES.length * NOUNS.length);

// The ends of both lists have to be reachable and in range. A `<=` in the index
// maths, or a rand() that can return 1, walks off the end and yields
// "undefined undefined" -- which would sail through as a handle.
assert.strictEqual(aliasFrom(() => 0), `${ADJECTIVES[0]} ${NOUNS[0]}`);
assert.strictEqual(
  aliasFrom(() => 0.999999),
  `${ADJECTIVES[ADJECTIVES.length - 1]} ${NOUNS[NOUNS.length - 1]}`,
);

// Two draws per alias, adjective first: pinned so a reordering of the picks
// can't quietly change what a given random sequence produces.
const sequence = [0, 0.5];
assert.strictEqual(
  aliasFrom(() => sequence.shift()),
  `${ADJECTIVES[0]} ${NOUNS[Math.floor(0.5 * NOUNS.length)]}`,
);

// And the shape the rest of the page assumes: exactly two words, one space.
for (let i = 0; i < 200; i++) {
  assert.match(aliasFrom(), /^[A-Z][a-z]+ [A-Z][a-z]+$/);
}

console.log(`ok: ${ALIAS_COUNT} aliases, none longer than ${MAX_HANDLE} chars`);
console.log('ok: wordlists are unique, capitalised, and reachable end to end');
