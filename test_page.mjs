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
import { dirname } from 'node:path';

// Every page that runs a module of its own. The admin pages are the same shape
// as the game and reached by one person, which makes a dead one *more* likely to
// sit unnoticed rather than less: nobody loads them until the day they need to.
// The floors are per page and exist so that a regex which stopped matching fails
// here rather than passing over an empty list.
const PAGES = [
  { path: 'web/index.html', imports: 4, ids: 20 },
  { path: 'web/admin/index.html', imports: 2, ids: 5 },
  { path: 'web/admin/notes.html', imports: 1, ids: 3 },
];

// Only a page's own modules. Anything from a CDN or a vendored global is loaded
// as a classic script and has no bindings to check. Absolute as well as
// relative: the admin pages sit a directory down and import from the site root.
const IMPORT = /import\s*\{([^}]+)\}\s*from\s*'(\.?\/[^']+)'/g;

const ID = /\bel\('([^']+)'\)/g;
const ATTR = /\bid="([^"]+)"/g;

// Resolved from the page that wrote it, which is what the browser does: './x'
// is a sibling of the page, '/x' is off the site root, and web/ is the root.
const resolve = (page, from) =>
  from.startsWith('/') ? `./web${from}` : `./${dirname(page)}/${from.slice(2)}`;

for (const { path, imports: floor, ids: idFloor } of PAGES) {
  const page = readFileSync(path, 'utf8');

  const imports = [...page.matchAll(IMPORT)];
  // A page that suddenly imports nothing means the regex stopped matching, not
  // that it stopped having dependencies -- and a test asserting over an empty
  // list passes loudly.
  assert.ok(imports.length >= floor,
    `only found ${imports.length} module imports in ${path}`);

  for (const [, names, from] of imports) {
    const module = await import(resolve(path, from));
    for (const name of names.split(',').map(n => n.trim()).filter(Boolean)) {
      // `a as b` imports the binding on the left; the pages have none today, but
      // splitting on it costs one line and failing on it would be a puzzle.
      const binding = name.split(/\s+as\s+/)[0];
      assert.ok(binding in module,
        `${path} imports { ${binding} } from '${from}', which does not export it`);
    }
  }

  console.log(`ok: all ${imports.length} of ${path}'s module imports resolve`);

  // The other half of the same gap: el() is getElementById, so a lookup naming an
  // id the markup does not carry returns null and throws only when that line runs
  // -- which for a recap or an end-of-game path is minutes into a session nothing
  // automated reaches. Every call site passes a literal, so the check is a set
  // difference.
  //
  // Not hypothetical: the eight ids lowercased for htmlhint were renamed in the
  // markup while three lookups written on a branch still spelled them camelCase.
  const looked = new Set([...page.matchAll(ID)].map(m => m[1]));
  const present = new Set([...page.matchAll(ATTR)].map(m => m[1]));
  assert.ok(looked.size >= idFloor, `only found ${looked.size} el() lookups in ${path}`);

  const missing = [...looked].filter(id => !present.has(id));
  assert.deepEqual(missing, [],
    `${path} looks up ids that no element carries: ${missing.join(', ')}`);

  console.log(`ok: all ${looked.size} el() lookups in ${path} name an element it has`);
}
