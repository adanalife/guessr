// Check that the page's imports resolve, which nothing else here can.
//
// The game lives in an inline `<script type="module">`, so every module it pulls
// in is resolved by the browser and by nothing in this repo. That leaves one
// gap, and it is the worst-shaped gap a static site can have: a named import
// that its module does not export is a *load-time* SyntaxError, so the whole
// script never runs. Not the recap, not the daily -- the page renders its markup
// and does nothing at all, on every browser at once.
//
// Nothing upstream sees it. The unit tests import the modules directly and never
// read index.html; `node --check` parses the extracted script and does not
// resolve bindings; the integration suite and smoke.sh both assert on endpoints,
// which answer perfectly while the page in front of them is dead. CI is entirely
// green for it.
//
// It is also easy to cause. A helper with no callers gets dropped -- correctly,
// by the audit that found it -- and comes back as a name a later feature
// imports because it used to be there. That is exactly how it happened:
// dayFromDate was removed as caller-less in #138 and imported again here.
import assert from 'node:assert/strict';
import { readFileSync } from 'node:fs';

const page = readFileSync('web/index.html', 'utf8');

// Only the page's own modules. Anything from a CDN or a vendored global is
// loaded as a classic script and has no bindings to check.
const IMPORT = /import\s*\{([^}]+)\}\s*from\s*'(\.\/[^']+)'/g;

const imports = [...page.matchAll(IMPORT)];
// A page that suddenly imports nothing means the regex stopped matching, not
// that the game stopped having dependencies -- and a test asserting over an
// empty list passes loudly.
assert.ok(imports.length >= 4, `only found ${imports.length} module imports in the page`);

for (const [, names, from] of imports) {
  const module = await import(`./web/${from.slice(2)}`);
  for (const name of names.split(',').map(n => n.trim()).filter(Boolean)) {
    // `a as b` imports the binding on the left; the page has none today, but
    // splitting on it costs one line and failing on it would be a puzzle.
    const binding = name.split(/\s+as\s+/)[0];
    assert.ok(binding in module,
      `web/index.html imports { ${binding} } from '${from}', which does not export it`);
  }
}

console.log(`ok: all ${imports.length} of the page's module imports resolve`);

// The other half of the same gap: el() is getElementById, so a lookup naming an
// id the markup does not carry returns null and throws only when that line runs
// -- which for a recap or an end-of-game path is minutes into a session nothing
// automated reaches. Every call site passes a literal, so the check is a set
// difference.
//
// Not hypothetical: the eight ids lowercased for htmlhint were renamed in the
// markup while three lookups written on a branch still spelled them camelCase.
const ID = /\bel\('([^']+)'\)/g;
const ATTR = /\bid="([^"]+)"/g;

const looked = new Set([...page.matchAll(ID)].map(m => m[1]));
const present = new Set([...page.matchAll(ATTR)].map(m => m[1]));
assert.ok(looked.size >= 20, `only found ${looked.size} el() lookups in the page`);

const missing = [...looked].filter(id => !present.has(id));
assert.deepEqual(missing, [],
  `web/index.html looks up ids that no element carries: ${missing.join(', ')}`);

console.log(`ok: all ${looked.size} el() lookups name an element the page has`);
