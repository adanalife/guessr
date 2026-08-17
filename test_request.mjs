// Cover the request deadline.
//
// Worth testing because the condition it exists for is the one a browser will
// not reproduce on demand. A stalled connection is not a connection that
// refuses -- the socket is open, the request is sent, and nothing ever comes
// back -- so the failure it causes cannot be reached by pulling a cable or
// stopping the server, and it looks like a working page right up until it
// doesn't. A node server that accepts and then says nothing is that condition,
// exactly, on demand.
//
// The property under test is only that a request always settles: either the
// response, or a rejection the caller can act on. What each caller does with
// the rejection is theirs -- scoring offers the guess again, the admin day puts
// a message where `loading…` was.

import assert from 'node:assert/strict';
import http from 'node:http';
import { TIMEOUT_MS, request, withDeadline } from './web/request.js';

// Short enough that the suite doesn't wait out a real deadline, long enough not
// to race a localhost round trip on a loaded machine.
const DEADLINE = 300;
const soon = withDeadline(DEADLINE);

// Every request gets one, and it is the same one -- the endpoints are all single
// indexed lookups, so there is no per-caller tuning to get wrong.
assert.equal(typeof TIMEOUT_MS, 'number');
assert.ok(TIMEOUT_MS > 0, 'a deadline of zero or less would abort every request');
assert.equal(typeof request, 'function', 'the shipped request must be callable');

// Accepts the connection and then never answers: the case the deadline exists
// for. `serve` hands back the base URL and a way to stop it.
async function serve(handler) {
  const srv = http.createServer(handler);
  await new Promise(r => srv.listen(0, '127.0.0.1', r));
  return {
    url: `http://127.0.0.1:${srv.address().port}`,
    // Sockets are destroyed rather than drained: a stalled request is still
    // holding one open, and close() alone would wait for it forever -- which is
    // the very hang this file is about, relocated into the test.
    stop: () => new Promise(r => { srv.closeAllConnections(); srv.close(r); }),
  };
}

// Nothing here may wait on a request without a bound of its own. A regression
// that drops the deadline makes the request pending forever, and awaiting that
// directly would hang the suite instead of failing it -- a test that reports
// nothing is barely better than the bug.
function within(ms, promise) {
  let timer;
  const bound = new Promise((_, reject) => {
    timer = setTimeout(
      () => reject(new Error(`nothing settled in ${ms}ms -- the deadline is not being applied`)),
      ms,
    );
  });
  return Promise.race([promise, bound]).finally(() => clearTimeout(timer));
}

// A connection that goes away without closing.
{
  const stalled = await serve(() => {});
  const began = Date.now();
  await assert.rejects(
    within(DEADLINE * 4, soon(`${stalled.url}/api/score`, { method: 'POST' })),
    e => {
      assert.equal(e.name, 'TimeoutError', `a stalled request rejected as ${e.name}`);
      // What scoreGuess's caller branches on. A transport failure carries no
      // verdict from the server, so it must not read as the final kind that
      // stops the page offering the guess again.
      assert.equal(e.final, undefined, 'a timeout must not look like a refusal');
      return true;
    },
    'a request to a server that never answers did not reject',
  );
  const took = Date.now() - began;
  // Early would mean something other than the deadline ended it; the ceiling is
  // the watchdog's job.
  assert.ok(took >= DEADLINE - 50, `gave up after ${took}ms, before its deadline`);
  await stalled.stop();
  console.log('ok: a request to a server that never answers gives up, and says which failure it was');
}

// The other half of the property, and the reason the deadline is generous: a
// request that answers slowly is not a request to abandon.
{
  const slow = await serve((_req, res) => {
    setTimeout(() => {
      res.writeHead(200, { 'content-type': 'application/json' });
      res.end(JSON.stringify({ rounds: ['a'] }));
    }, DEADLINE / 3);
  });
  const res = await soon(`${slow.url}/api/day?practice`);
  assert.equal(res.status, 200);
  assert.deepEqual((await res.json()).rounds, ['a'], 'a slow answer did not arrive whole');
  await slow.stop();
  console.log('ok: an answer inside the deadline still arrives');
}

// The deadline is added to what a caller asked for, not instead of it -- scoring
// and the device merge both post a body, and a wrapper that dropped the method
// or the payload would fail in a way no local test of the handler would show.
{
  const seen = [];
  const echo = await serve((req, res) => {
    const chunks = [];
    req.on('data', c => chunks.push(c));
    req.on('end', () => {
      seen.push({
        method: req.method,
        type: req.headers['content-type'],
        body: Buffer.concat(chunks).toString(),
      });
      res.writeHead(200, { 'content-type': 'application/json' });
      res.end('{}');
    });
  });
  await soon(`${echo.url}/api/score`, {
    method: 'POST',
    headers: { 'content-type': 'application/json' },
    body: JSON.stringify({ image: 'x.mp4', lat: 1, lng: 2 }),
  });
  assert.deepEqual(seen, [{
    method: 'POST',
    type: 'application/json',
    body: '{"image":"x.mp4","lat":1,"lng":2}',
  }], 'the deadline replaced the request instead of bounding it');
  await echo.stop();
  console.log('ok: the method, headers and body a caller asked for survive the deadline');
}
