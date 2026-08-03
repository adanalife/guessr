// Cover the share string and the score bands under it.
//
// Worth testing because it is the one output nothing else checks and nothing
// fails loudly about. A wrong band renders a perfectly good-looking row of
// squares; a share string missing its link still copies to the clipboard and
// still reads like a score. The only detector is a person looking at a paste and
// knowing what it should have said, which is not a detector.
//
// And it is the top of the funnel: a shared result is how someone who does not
// already watch the stream finds the game, so HOME_URL being present is not a
// cosmetic property.

import assert from 'node:assert/strict';
import {
  BANDS, HOME_URL, MAX_ROUND_SCORE, bandFor, scoreLine, shareText, squareFor,
} from './web/share.js';

// The table is a first-match lookup, so descending order is what makes it a
// lookup at all. Sorted any other way -- by colour, alphabetically, or reversed
// by someone tidying -- every score clears the first row and every round gets
// the same square, silently.
const mins = BANDS.map(b => b.min);
assert.deepEqual(mins, [...mins].sort((a, b) => b - a), 'BANDS is not ordered best first');
assert.equal(mins.at(-1), 0, 'the last band must catch a zero score');
assert.equal(new Set(mins).size, mins.length, 'two bands share a cutoff');
// A duplicate square or colour would make two bands indistinguishable on the
// share string and on the end-of-game map respectively.
assert.equal(new Set(BANDS.map(b => b.square)).size, BANDS.length, 'two bands share a square');
assert.equal(new Set(BANDS.map(b => b.colour)).size, BANDS.length, 'two bands share a colour');

// Every band has to be reachable by a real score, or it is decoration.
const reachable = new Set();
for (let pts = 0; pts <= MAX_ROUND_SCORE; pts++) reachable.add(bandFor(pts).square);
assert.equal(reachable.size, BANDS.length,
  `only ${reachable.size} of ${BANDS.length} bands are reachable from a real score`);

// Both edges of every cutoff, which is the off-by-one that would quietly
// re-grade a whole day of scores.
for (const { min, square } of BANDS) {
  assert.equal(squareFor(min), square, `${min} did not land in its own band`);
  if (min > 0) {
    assert.notEqual(squareFor(min - 1), square, `${min - 1} landed in the band above it`);
  }
}

// A perfect round is the best band and a zero is the worst -- pinned directly,
// because the loop above is satisfied by any consistent table including an
// inverted one.
assert.equal(squareFor(MAX_ROUND_SCORE), BANDS[0].square, 'a perfect round is not the top band');
assert.equal(squareFor(0), BANDS.at(-1).square, 'a zero is not the bottom band');

// Never undefined across the whole range a server-side score can take. bandFor
// returns from Array.find, so a gap in the table throws on `.square` rather than
// degrading -- which on the finished screen is a blank page, not a wrong colour.
for (const pts of [0, 1, 999, 1000, 2499, 2500, 3999, 4000, 4999, 5000]) {
  assert.ok(bandFor(pts), `no band for ${pts}`);
  assert.ok(squareFor(pts), `no square for ${pts}`);
}

// The string itself. Four lines, in the order a reader scans them.
{
  const res = [5000, 3000, 1200, 400, 4800];
  const sum = res.reduce((a, b) => a + b, 0);
  const lines = shareText(42, res, sum).split('\n');

  assert.equal(lines.length, 4, 'the share string is not four lines');
  assert.equal(lines[0], 'Guessr #42');
  assert.equal(lines[1], '🟩🟨🟧⬜🟩');
  // Not asserted against a literal '19,400': toLocaleString follows the runtime's
  // locale, and a machine set to fr-FR groups with spaces. The grouping is the
  // player's to have; the digits are ours.
  assert.equal(lines[2].replace(/\D/g, ''), `${sum}${res.length * MAX_ROUND_SCORE}`,
    `the total line does not read ${sum} / ${res.length * MAX_ROUND_SCORE}`);
  assert.equal(lines[3], HOME_URL, 'the share string does not end with somewhere to play');

  // One square per round, always -- a game that ended early still shares as many
  // squares as it played.
  for (const n of [1, 2, 3, 4, 5]) {
    const partial = res.slice(0, n);
    const text = shareText(1, partial, 0);
    assert.equal([...text.split('\n')[1]].length, n, `${n} rounds did not make ${n} squares`);
    assert.equal(text.split('\n')[2].replace(/\D/g, ''), `0${n * MAX_ROUND_SCORE}`,
      'the denominator does not follow the rounds actually played');
  }
}

// The link is the whole reason a paste is worth anything, and it must be the
// canonical host rather than wherever the tab happened to be served from -- a
// result shared off a preview deploy still has to send people to the real game.
assert.match(HOME_URL, /^https:\/\/guessr\.dana\.lol$/, 'HOME_URL is not the canonical origin');
assert.ok(shareText(1, [0], 0).includes(HOME_URL), 'a zero-score share still needs the link');

// The page and the paste read from one table, so a round can never be green in
// the share string and orange on the map.
{
  const res = [5000, 3000, 1200, 400, 4800];
  const squares = shareText(7, res, 14400).split('\n')[1];
  for (const square of squares) {
    assert.ok(scoreLine(res, 14400).includes(square),
      `${square} is in the share string but not on the page`);
  }
  assert.ok(scoreLine(res, 14400).includes('<span class="squares">'),
    'scoreLine stopped wrapping its squares, so the page cannot style them');
}

console.log('ok: score bands are ordered, reachable, and exact at every cutoff');
console.log('ok: a share string is four lines, one square a round, and carries the link');
