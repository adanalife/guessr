// Cover the root middleware: it hands the dynamic routes to the Worker, and for
// any other path it is invisible.
import assert from 'node:assert/strict';

import { onRequest } from './functions/_middleware.js';

const NEXT = new Response('pages');
const WORKER = new Response('worker');

async function route(path) {
  const seen = [];
  const API = { fetch: async req => { seen.push(req); return WORKER; } };
  const request = new Request(`https://stage.guessr.dana.lol${path}`);
  const res = await onRequest({ request, env: { API }, next: async () => NEXT });
  return { res, seen, request };
}

for (const path of ['/api/day?date=2026-09-23', '/admin/', '/admin/day']) {
  const { res, seen, request } = await route(path);
  assert.equal(res, WORKER, `${path} was not forwarded to the Worker`);
  assert.equal(seen.length, 1);
  assert.equal(seen[0].url, request.url, `${path} reached the Worker as a different request`);
}

// A path the Worker does not own: the site, its assets and the clips (served
// from R2 by `functions/clips/`). `/apix` and `/admin`
// are the prefix-without-slash cases.
for (const path of ['/', '/index.html', '/version.json', '/daily.js', '/apix', '/admin', '/clips/a.mp4']) {
  const { res, seen } = await route(path);
  assert.equal(res, NEXT, `${path} was forwarded but belongs to Pages`);
  assert.equal(seen.length, 0);
}

// Cloudflare's 1101 as a request with `Accept: application/json` gets it.
const CF_1101_JSON = JSON.stringify({
  type: 'https://developers.cloudflare.com/support/troubleshooting/http-status-codes/cloudflare-1xxx-errors/error-1101/',
  title: 'Error 1101: Worker threw exception',
  status: 500,
  error_code: 1101,
  error_name: 'worker_threw_exception',
  cloudflare_error: true,
});

// A broken Python isolate: the binding's fetch rejects, or answers Cloudflare's
// own 1101 page, as text or as JSON. Each is tried again, a POST with its body
// intact, and the third failure is what the player gets.
async function flaky(failures, request = new Request('https://stage.guessr.dana.lol/api/score', { method: 'POST', body: '{"g":1}' })) {
  const bodies = [];
  let calls = 0;
  const API = {
    fetch: async req => {
      bodies.push(await req.text());
      const failure = failures[calls++];
      if (failure === 'reject') throw new Error('NoGilError');
      if (failure === '1101') return new Response('error code: 1101', { status: 500 });
      if (failure === '1101json') return new Response(CF_1101_JSON, { status: 500 });
      return WORKER;
    },
  };
  const res = await onRequest({ request, env: { API }, next: async () => NEXT }).catch(err => err);
  return { res, calls, bodies };
}

for (const failure of ['reject', '1101', '1101json']) {
  const { res, calls, bodies } = await flaky([failure]);
  assert.equal(res, WORKER, `a ${failure} was not tried again`);
  assert.equal(calls, 2);
  assert.deepEqual(bodies, ['{"g":1}', '{"g":1}'], `a ${failure} retry lost the POST body`);
}

{
  const { res, calls } = await flaky(['reject', '1101', 'reject']);
  assert.ok(res instanceof Error, 'a third rejection was swallowed');
  assert.equal(calls, 3);
}
{
  const { res, calls } = await flaky(['1101', '1101', '1101']);
  assert.equal(res.status, 500);
  assert.equal(await res.text(), 'error code: 1101');
  assert.equal(calls, 3);
}

// The app's own 500 is an answer, not a broken isolate: passed through once.
{
  let calls = 0;
  const own = new Response('{"error":"boom"}', { status: 500 });
  const API = { fetch: async () => { calls++; return own; } };
  const request = new Request('https://stage.guessr.dana.lol/api/day');
  const res = await onRequest({ request, env: { API }, next: async () => NEXT });
  assert.equal(res, own);
  assert.equal(calls, 1);
}

console.log('ok: forward');
