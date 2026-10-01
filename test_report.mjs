// Cover /api/report: who may report a round, how often, and what is in the
// message that goes out.
//
// Everything here is a property that fails silently in production. The gate is
// the only thing between this endpoint and an open Discord webhook, and it
// fails *open* -- a report that is accepted from someone with no play just
// posts a message, which looks exactly like a real one. The once-only claim
// has the same shape: a second report costs a webhook post nobody sees twice,
// so a broken claim is a bill and a noisy channel rather than an error.
//
// The tier label is here for the same reason. It is one word in a string, and
// getting it wrong means staging's tests and real player reports are the same
// message in the same channel.
import assert from 'node:assert/strict';

import { d1, post, schema, seedAnswers } from './_d1.mjs';
import { onRequestPost } from './functions/api/report.js';

const DATE = '2026-09-17';
const MINE = 'clips/mine-010000.mp4';
const THEIRS = 'clips/theirs-020000.mp4';
const ME = 'player-me';
const THEM = 'player-them';

const assets = {
  async fetch() {
    return new Response(JSON.stringify({ label: 'stage', tier: 'staging' }));
  },
};

function seeded() {
  const answers = d1(schema());
  seedAnswers(answers.db, [MINE, THEIRS]);
  answers.db.exec(`
    INSERT INTO rounds (image, median_km, mean_cos, batch, slug, source_ts_sec,
                        clip_ts_sec, radius_m)
    VALUES ('${MINE}', 8.0, 0.1, 'b1', 'van-day-12', 431.5, 431.5, 90.0)`);
  answers.db.exec(`
    INSERT INTO round_days (date, position, image) VALUES ('${DATE}', 3, '${MINE}')`);
  const play = answers.db.prepare(
    `INSERT INTO plays (date, player_id, image, km, points, guess_lat, guess_lng)
     VALUES (?, ?, ?, 42.0, 3100, 41.8781, -87.6298)`);
  play.run(DATE, ME, MINE);
  play.run(DATE, THEM, THEIRS);
  return answers;
}

// One webhook that remembers what it was sent, so the message can be asserted
// on rather than only the status code -- the message is the entire product of
// this endpoint.
function webhook({ ok = true } = {}) {
  const sent = [];
  globalThis.fetch = async (url, opts) => {
    sent.push({ url, content: JSON.parse(opts.body).content });
    return new Response(null, { status: ok ? 204 : 500 });
  };
  return sent;
}

const report = (env, body) => onRequestPost({
  request: Object.assign(post(body), { url: 'https://stage.guessr.dana.lol/api/report' }),
  env,
});

const WEBHOOK = 'https://discord.test/hook';

{
  const answers = seeded();
  const sent = webhook();
  const env = { ANSWERS: answers, ASSETS: assets, DISCORD_WEBHOOK: WEBHOOK };

  // A play this player really recorded. The report goes out and the play is
  // marked, which is the pair the rest of this file leans on.
  const first = await report(env, { date: DATE, player_id: ME, image: MINE });
  assert.equal(first.status, 200);
  assert.deepEqual(await first.json(), { reported: true });
  assert.equal(sent.length, 1, 'a report did not reach the webhook');
  assert.equal(sent[0].url, WEBHOOK);

  // The message names the tier, the moment inside the source recording, and the
  // pin -- the three things that make it actionable. The moment in particular:
  // a report naming only the clip is coarser than the per-moment row the
  // correction has to be written against.
  const { content } = sent[0];
  assert.match(content, /^\*\*\[staging\]/, 'a report did not say which tier sent it');
  assert.match(content, /van-day-12/, 'the message did not name the source clip');
  assert.match(content, /432s/, 'the message did not name the moment within it');
  assert.match(content, /round 3/, 'the message did not say which round it was');
  assert.match(content, /41\.8781, -87\.6298/, 'the message did not carry the pin');
  assert.match(content, /42 km/, 'the message did not say how far off the guess was');

  // Once. The claim is the rate limit, so a second press -- or a loop -- has to
  // post nothing while still reading as success to the player, who did report
  // it and has no use for the distinction.
  const again = await report(env, { date: DATE, player_id: ME, image: MINE });
  assert.equal(again.status, 200);
  assert.deepEqual(await again.json(), { reported: true, already: true });
  assert.equal(sent.length, 1, 'a repeated report sent a second message');

  // Somebody else's play, and a round nobody played. Both are refused before
  // anything is sent: without this the endpoint forwards whatever a script
  // names, and the only visible symptom is reports that read fine.
  for (const body of [
    { date: DATE, player_id: ME, image: THEIRS },
    { date: DATE, player_id: 'player-nobody', image: MINE },
    { date: '2026-09-16', player_id: ME, image: MINE },
  ]) {
    const refused = await report(env, body);
    assert.equal(refused.status, 403, `reported a play that is not theirs: ${JSON.stringify(body)}`);
  }
  assert.equal(sent.length, 1, 'a refused report still reached the webhook');

  // Malformed bodies, which must not read as "not yours" -- a client that sent
  // the wrong shape should be told that, not told to stop asking.
  for (const body of [
    undefined, null, {}, { date: DATE, player_id: ME },
    { date: 'today', player_id: ME, image: MINE },
    { date: DATE, player_id: '', image: MINE },
    { date: DATE, player_id: ME, image: 42 },
  ]) {
    assert.equal((await report(env, body)).status, 400,
      `a malformed body was not a 400: ${JSON.stringify(body)}`);
  }
}

{
  // No binding -- staging until its webhook is set. The refusal comes before
  // the claim, so the player's one report on that round is still available
  // once the binding exists.
  const answers = seeded();
  const sent = webhook();
  const env = { ANSWERS: answers, ASSETS: assets };

  const refused = await report(env, { date: DATE, player_id: THEM, image: THEIRS });
  assert.equal(refused.status, 503);
  assert.equal(sent.length, 0);
  assert.equal(
    answers.db.prepare('SELECT reported_at FROM plays WHERE player_id = ?').get(THEM).reported_at,
    null, 'a report nothing could deliver still marked the play reported');
}

{
  // Discord refused it. Same requirement, one layer out: a report held down by
  // an outage must be reportable again rather than permanently spent.
  const answers = seeded();
  webhook({ ok: false });
  const env = { ANSWERS: answers, ASSETS: assets, DISCORD_WEBHOOK: WEBHOOK };

  const failed = await report(env, { date: DATE, player_id: ME, image: MINE });
  assert.equal(failed.status, 502);
  assert.equal(
    answers.db.prepare('SELECT reported_at FROM plays WHERE player_id = ?').get(ME).reported_at,
    null, 'a failed delivery left the play unreportable');
}

console.log('ok: only a play the reporter recorded can be reported');
console.log('ok: a report is forwarded once, however many times it is sent');
console.log('ok: the message names the tier, the moment and the pin');
console.log('ok: a report that could not be delivered can be sent again');
