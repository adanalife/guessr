// Checks the changelog renderer. Run with `node test_changelog.js`
// (or `task test`).
//
// changelog.js is a plain script rather than a module, so eval in this scope is
// how the test gets at its functions — the same arrangement test_zoom.js uses.
const assert = require('node:assert');
const fs = require('node:fs');

eval(fs.readFileSync(`${__dirname}/web/changelog.js`, 'utf8'));

// A release-please CHANGELOG, in the shape it actually emits.
const sample = `# Changelog

## [0.2.0](https://github.com/adanalife/guessr/compare/v0.1.0...v0.2.0) (2026-08-01)


### Features

* **web:** let players zoom and pan the frame ([#10](https://github.com/adanalife/guessr/issues/10)) ([3124613](https://github.com/adanalife/guessr/commit/3124613))
`;

const html = renderChangelog(sample);

// Headings and bullets come through as their own elements.
assert.match(html, /<h4><a href="[^"]+">0\.2\.0<\/a> \(2026-08-01\)<\/h4>/);
assert.match(html, /<h5>Features<\/h5>/);
assert.match(html, /<div class="bullet"><b>web:<\/b> let players zoom/);
// Both links in the bullet survive as links.
assert.strictEqual((html.match(/<a href=/g) || []).length, 3);
// The `# Changelog` title and the blank lines are dropped, not rendered.
assert.ok(!html.includes('Changelog'), 'the h1 title should be dropped');

// The changelog is generated, but it quotes commit subjects that aren't, so
// markup in one must not reach the page as markup.
const nasty = renderChangelog('* fix: escape <img src=x onerror=alert(1)> & co');
assert.ok(!nasty.includes('<img'), 'raw HTML must be escaped');
assert.ok(nasty.includes('&lt;img'), 'escaped form should be visible');
assert.ok(nasty.includes('&amp; co'), 'ampersands are escaped once');

console.log('changelog rendering ok');
