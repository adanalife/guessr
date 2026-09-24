// Check which hosts web/sentry-init.js reports from.
//
// The failure it guards is quiet in both directions: a production host that
// maps to `development` sends nothing, so the dashboard reads as a game with no
// bugs, and a preview that maps to `prod-1` files someone's half-finished branch
// against the live game. Neither throws.
//
// The file is a classic script, so it runs here the way a browser runs it -- in
// a context with `location` and a stand-in `Sentry` that records what it was
// given.
import assert from 'node:assert/strict';
import { readFileSync } from 'node:fs';
import { runInNewContext } from 'node:vm';

const source = readFileSync(new URL('./web/sentry-init.js', import.meta.url), 'utf8');

function optionsFor(hostname) {
  let options;
  runInNewContext(source, {
    location: { hostname },
    Sentry: { init: o => { options = o; }, replayIntegration: () => 'replay' },
  });
  return options;
}

const cases = [
  ['guessr.dana.lol', 'prod-1', true],
  ['stage.guessr.dana.lol', 'stage-1', true],
  ['recap.adanalife-guessr.pages.dev', 'development', false],
  ['adanalife-guessr.pages.dev', 'development', false],
  ['localhost', 'development', false],
  ['127.0.0.1', 'development', false],
  // A lookalike that merely ends in the production name is not production.
  ['evil-guessr.dana.lol', 'development', false],
];

for (const [hostname, environment, enabled] of cases) {
  const o = optionsFor(hostname);
  assert.equal(o.environment, environment, hostname);
  assert.equal(o.enabled, enabled, hostname);
  assert.equal(o.sendDefaultPii, false, hostname);
  // Replay on error only: a full-session rate would spend the fleet's quota
  // on sessions that never errored.
  assert.deepEqual([...o.integrations], ['replay'], hostname);
  assert.equal(o.replaysSessionSampleRate, 0, hostname);
  assert.equal(o.replaysOnErrorSampleRate, 1.0, hostname);
  assert.match(o.dsn, /^https:\/\/[0-9a-f]+@o\d+\.ingest\.us\.sentry\.io\/\d+$/, hostname);
}

console.log(`ok  ${cases.length} hosts`);
