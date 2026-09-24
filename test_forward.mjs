// Cover the root middleware: with an API binding it hands the dynamic routes to
// the Worker, and without one -- or for any other path -- it is invisible.
import assert from 'node:assert/strict';

import { onRequest } from './functions/_middleware.js';

const NEXT = new Response('pages');
const WORKER = new Response('worker');

async function route(path, env) {
  const seen = [];
  const API = { fetch: async req => { seen.push(req); return WORKER; } };
  const request = new Request(`https://stage.guessr.dana.lol${path}`);
  const res = await onRequest({ request, env: env === 'bound' ? { API } : {}, next: async () => NEXT });
  return { res, seen, request };
}

for (const path of ['/api/day?date=2026-09-23', '/admin/', '/admin/day', '/clips/a.mp4']) {
  const { res, seen, request } = await route(path, 'bound');
  assert.equal(res, WORKER, `${path} was not forwarded to the Worker`);
  assert.equal(seen[0], request, `${path} reached the Worker as a different request`);
}

// Bound, but a path the Worker does not own: the site and its assets. `/apix`
// and `/admin` are the prefix-without-slash cases.
for (const path of ['/', '/index.html', '/version.json', '/daily.js', '/apix', '/admin']) {
  const { res, seen } = await route(path, 'bound');
  assert.equal(res, NEXT, `${path} was forwarded but belongs to Pages`);
  assert.equal(seen.length, 0);
}

// Unbound: production and `wrangler pages dev`. Nothing is forwarded, the
// dynamic routes included.
for (const path of ['/api/day', '/admin/', '/clips/a.mp4', '/']) {
  const { res } = await route(path, 'unbound');
  assert.equal(res, NEXT, `${path} did not fall through with no binding`);
}

console.log('ok: forward');
