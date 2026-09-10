#!/usr/bin/env node
// Resolve the deployed page's module graph, against the bytes a browser would
// get: ./deployed_imports.mjs https://guessr.dana.lol
//
// test_page.mjs asks the same question of the working tree, and that catches the
// refactor that drops an export a page still imports -- a load-time SyntaxError,
// so the inline module never runs and the page renders its markup and does
// nothing, game included. What it cannot see is the deployed tier: a build that
// shipped a stale daily.js beside a fresh index.html has the same symptom and a
// green working tree, and every endpoint smoke.sh asserts on answers perfectly
// while the page in front of them is dead.
//
// The modules are fetched into a temp directory that mirrors the site's paths,
// then imported from there -- so a nested import resolves the way the browser
// resolves it, and the binding check is the real one rather than a regex over
// the source.
import assert from 'node:assert/strict';
import { mkdir, mkdtemp, writeFile } from 'node:fs/promises';
import { tmpdir } from 'node:os';
import { dirname, join } from 'node:path';
import { pathToFileURL } from 'node:url';

const BASE = process.argv[2];
if (!BASE) {
  console.error('usage: deployed_imports.mjs <base-url>');
  process.exit(2);
}

// Only the page's own modules, same as test_page.mjs: a CDN script is classic
// and has no bindings to resolve. Absolute as well as relative, since a module a
// directory down imports from the site root.
const IMPORT = /import\s*\{([^}]+)\}\s*from\s*'(\.?\/[^']+)'/g;

// A path with no file behind it answers 200 with the site's own HTML on Pages,
// so status is silent on whether a module is there and the content type is the
// only thing that says so. This is the assertion that catches a dead import.
const JS = /^(application|text)\/(javascript|ecmascript)/;

const dir = await mkdtemp(join(tmpdir(), 'guessr-modules-'));

// Fetched breadth-first from the page, so the check follows the graph the
// browser would rather than one level of it.
const seen = new Set();
const bindings = [];
const queue = [{ path: '/', from: 'the deployment' }];
let pageImports = 0;

while (queue.length) {
  const { path, from } = queue.shift();
  if (seen.has(path)) continue;
  seen.add(path);

  const url = new URL(path, BASE);
  const res = await fetch(url);
  const body = await res.text();
  const ctype = res.headers.get('content-type') ?? '';

  if (path !== '/') {
    assert.ok(JS.test(ctype),
      `${url} is served as '${ctype}' (HTTP ${res.status}), not JavaScript -- ` +
      `Pages answers a path it holds no file for with the site's HTML and a 200, ` +
      `so this is a module ${from} imports that this deployment does not carry.`);
    await mkdir(join(dir, dirname(path)), { recursive: true });
    await writeFile(join(dir, path), body);
  }

  const imports = [...body.matchAll(IMPORT)];
  if (path === '/') pageImports = imports.length;

  for (const [, names, spec] of imports) {
    const target = new URL(spec, url).pathname;
    queue.push({ path: target, from: path });
    // Checked after the whole graph is on disk, so a nested import resolves.
    bindings.push({ page: path, target, names, spec });
  }
}

// A page that suddenly imports nothing means the regex stopped matching, not
// that the page stopped having dependencies -- and a check over an empty list
// passes loudly. web/index.html carries seven today.
assert.ok(pageImports >= 4,
  `only found ${pageImports} module imports in ${BASE} -- the page is not the game's`);

for (const { page, target, names, spec } of bindings) {
  const module = await import(pathToFileURL(join(dir, target)).href);
  for (const name of names.split(',').map(n => n.trim()).filter(Boolean)) {
    // `a as b` imports the binding on the left.
    const binding = name.split(/\s+as\s+/)[0];
    assert.ok(binding in module,
      `${page} imports { ${binding} } from '${spec}', which the deployed module ` +
      `does not export -- the page's script is a load-time SyntaxError and the ` +
      `game does not run.`);
  }
}

console.log(`ok: the deployed page's ${pageImports} module imports resolve ` +
  `across ${seen.size - 1} fetched modules`);
