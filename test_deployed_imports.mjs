// Check that deployed_imports.mjs fails on the deploys it exists to catch.
//
// It is the only check in the repo whose subject is a URL, so the only way to
// pin it is to serve it one: a handful of fixture responses out of node:http,
// including the Pages behaviour that makes this hard -- a path with no file
// answers 200 with the site's HTML, so a module that never shipped looks like a
// module that did until you read the content type.
import assert from 'node:assert/strict';
import { execFile } from 'node:child_process';
import { createServer } from 'node:http';

const PAGE = names => `<!doctype html><script type="module">
import { ${names} } from './daily.js';
import { a } from './a.js';
import { b } from './b.js';
import { c } from './c.js';
</script>`;

const MODULES = {
  '/daily.js': "export const effectiveDay = 1;\nexport const ROUNDS_PER_GAME = 5;\n",
  '/a.js': 'export const a = 1;\n',
  '/b.js': 'export const b = 1;\n',
  '/c.js': 'export const c = 1;\n',
};

// The site's HTML with a 200, which is what Pages answers for a path it holds
// no file for -- the fixture's whole reason for existing.
let page = PAGE('effectiveDay');
let missing = new Set();

const server = createServer((req, res) => {
  const path = req.url;
  if (path !== '/' && MODULES[path] && !missing.has(path)) {
    res.writeHead(200, { 'content-type': 'text/javascript' });
    res.end(MODULES[path]);
    return;
  }
  res.writeHead(200, { 'content-type': 'text/html' });
  res.end(page);
});

await new Promise(done => server.listen(0, '127.0.0.1', done));
const base = `http://127.0.0.1:${server.address().port}`;

const run = () => new Promise(done =>
  execFile(process.execPath, ['deployed_imports.mjs', base], (err, stdout, stderr) =>
    done({ code: err?.code ?? 0, out: stdout + stderr })));

let r = await run();
assert.equal(r.code, 0, `a sound deployment should pass: ${r.out}`);
console.log('ok: a deployment whose modules all resolve passes');

missing.add('/b.js');
r = await run();
assert.notEqual(r.code, 0, 'a module answering the site HTML should fail');
assert.match(r.out, /not JavaScript/, r.out);
console.log('ok: a module the deployment does not carry fails on its content type');

missing.clear();
page = PAGE('effectiveDay, dayFromDate');
r = await run();
assert.notEqual(r.code, 0, 'an import nothing exports should fail');
assert.match(r.out, /does not export/, r.out);
console.log('ok: a named import the deployed module lacks fails');

page = '<!doctype html><script type="module">\nconst nothing = 1;\n</script>';
r = await run();
assert.notEqual(r.code, 0, 'a page with no imports at all should fail');
assert.match(r.out, /only found 0 module imports/, r.out);
console.log('ok: a page that imports nothing fails rather than passing over an empty list');

server.close();
