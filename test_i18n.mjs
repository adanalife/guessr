// Check that every string the page shows has a row in every language, and that
// no row has outlived its string.
//
// The translations are keyed on the English, so an edit to a sentence in
// index.html silently orphans its translation: the page falls back to English
// and nothing errors. This is the only thing that notices.
import assert from 'node:assert/strict';
import { readFileSync } from 'node:fs';
import { LANGUAGES, STRINGS, pickLanguage } from './web/i18n.js';

const page = readFileSync('web/index.html', 'utf8');
const squash = s => s.replace(/\s+/g, ' ').trim();

// An element marked `data-i18n` is keyed on its inner HTML. Lazy up to the
// first closing tag of the same name, which holds because no marked element
// nests one of its own kind.
const marked = [...page.matchAll(/<(\w+)\b[^>]*\bdata-i18n(?=[\s>])[^>]*>([\s\S]*?)<\/\1>/g)].map(m => squash(m[2]));
// Hand-parsed `data-i18n` that the regex above has to see; a tag written as
// `data-i18n>` with no space is the other spelling.
const markedFloor = [...page.matchAll(/\bdata-i18n(?=[\s>])/g)].length;
assert.equal(marked.length, markedFloor, 'a data-i18n element the key regex did not match');

const attrs = [...page.matchAll(/<[^>]*\bdata-i18n-attr="([^"]+)"[^>]*>/g)].flatMap(([tag, names]) =>
  names.split(' ').map(name => {
    const value = tag.match(new RegExp(`\\b${name}="([^"]*)"`));
    assert.ok(value, `data-i18n-attr names ${name}, which its tag does not carry: ${tag}`);
    return squash(value[1]);
  }));

// The script's own t() calls, in either quote.
const script = [...page.matchAll(/\bt\((['"])((?:\\.|(?!\1).)*)\1/g)].map(m => m[2].replace(/\\(.)/g, '$1'));

const used = new Set([...marked, ...attrs, ...script]);
assert.ok(used.size > 60, `only found ${used.size} keys on the page`);

for (const lang of LANGUAGES) {
  const table = STRINGS[lang];
  const missing = [...used].filter(k => !(k in table));
  assert.deepEqual(missing, [], `${lang} has no row for: ${missing.join(' | ')}`);
  const stale = Object.keys(table).filter(k => !used.has(k));
  assert.deepEqual(stale, [], `${lang} has rows the page no longer shows: ${stale.join(' | ')}`);
  // A slot the English has and the translation dropped would print as nothing;
  // one the translation invented would print as `{name}`.
  const slots = s => [...s.matchAll(/\{(\w+)\}|<(\w+)/g)].map(m => m[1] ?? `<${m[2]}`).sort();
  for (const [k, v] of Object.entries(table)) {
    assert.deepEqual(slots(v), slots(k), `${lang}: "${v}" carries different slots or tags from "${k}"`);
  }
}
console.log(`ok: ${used.size} keys, every one in ${LANGUAGES.join(', ')}`);

assert.equal(pickLanguage(['fr-CA', 'en']), 'fr');
assert.equal(pickLanguage(['de-DE', 'cs-CZ']), 'cs');
assert.equal(pickLanguage(['de-DE']), 'en');
assert.equal(pickLanguage(['en-US'], '?lang=ru'), 'ru');
assert.equal(pickLanguage(['es'], '?lang=xx'), 'es');
// The picker's saved choice beats the browser, and `?lang=` beats the choice.
assert.equal(pickLanguage(['fr'], '', 'cs'), 'cs');
assert.equal(pickLanguage(['fr'], '', 'en'), 'en');
assert.equal(pickLanguage(['fr'], '?lang=ru', 'cs'), 'ru');
assert.equal(pickLanguage(['fr'], '', 'xx'), 'fr');
console.log('ok: the language comes from the browser, and ?lang= overrides it');
