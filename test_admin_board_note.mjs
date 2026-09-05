// Cover /admin/board-note: the same note as /admin/players, addressed by board row.
//
// What carries the weight is that a rank names the player the caller thought it
// named. This route is how a note gets written from a surface holding no player
// id, so a rank resolved even slightly differently from the drilldown beside it
// writes a private note against the wrong person -- and nothing would say so.
// That is why it resolves through atRank() rather than its own query, and why
// the test below writes through this route and reads back by id.
import assert from 'node:assert/strict';

import { d1, schema, seedAnswers } from './_d1.mjs';
import { onRequestGet, onRequestPost } from './functions/admin/board-note.js';
import { onRequestGet as drilldown } from './functions/api/guesses.js';

const assets = tier => ({
  async fetch() {
    if (tier === undefined) return new Response('nope', { status: 404 });
    return new Response(JSON.stringify({ label: 'test', tier }));
  },
});

// Yesterday: the daily board serves the last *closed* date, so a fixture dated
// today would be a board the endpoint refuses rather than one with rows.
const CLOSED = new Date(Date.now() - 36 * 3600 * 1000).toISOString().slice(0, 10);

const WINNER = 'player-winner';
const RUNNER_UP = 'player-runner-up';

function seeded() {
  const answers = d1(schema());
  const images = ['clips/a-010000.mp4', 'clips/b-020000.mp4'];
  seedAnswers(answers.db, images);
  const play = answers.db.prepare(
    `INSERT INTO plays (date, player_id, image, km, points, handle)
     VALUES (?, ?, ?, 10.0, ?, ?)`);
  play.run(CLOSED, WINNER, images[0], 4800, 'Amber Basin');
  play.run(CLOSED, RUNNER_UP, images[1], 2200, 'Copper Vale');
  return answers;
}

const url = query => `https://stage.guessr.dana.lol/admin/board-note?${query}`;
const get = (tier, query, answers) => onRequestGet({
  request: new Request(url(query)),
  env: { ANSWERS: answers, ASSETS: assets(tier) },
});
const post = (tier, query, body, answers) => onRequestPost({
  request: new Request(url(query), { method: 'POST', body: JSON.stringify(body) }),
  env: { ANSWERS: answers, ASSETS: assets(tier) },
});
const noteOf = (answers, playerId) => answers.db
  .prepare('SELECT note FROM players WHERE player_id = ?').get(playerId)?.note ?? null;

// THE ONE THAT MATTERS. A rank has to name the same player here as it does in
// the drilldown a caller clicked, or a note lands on somebody else.
for (const [rank, playerId] of [[1, WINNER], [2, RUNNER_UP]]) {
  const answers = seeded();
  const query = `board=daily&rank=${rank}&date=${CLOSED}`;

  const shown = await (await drilldown({
    request: new Request(`https://guessr.dana.lol/api/guesses?${query}`),
    env: { ANSWERS: answers },
  })).json();

  const res = await post('production', query, { note: `note for ${rank}` }, answers);
  assert.equal(res.status, 200, `rank ${rank} could not be noted`);
  const saved = await res.json();

  assert.equal(saved.name, shown.name,
    `the note went to a different player than the drilldown at rank ${rank} shows`);
  assert.equal(noteOf(answers, playerId), `note for ${rank}`,
    `rank ${rank} resolved to the wrong player id`);
  // And nobody else was touched.
  const other = playerId === WINNER ? RUNNER_UP : WINNER;
  assert.equal(noteOf(answers, other), null, 'a note landed on the other player too');
}

// A note is private, so this route is gated exactly like the rest of /admin/ --
// and the refusal carries no note.
for (const tier of [undefined, 'PRODUCTION', '', null]) {
  const answers = seeded();
  await post('production', `board=daily&rank=1&date=${CLOSED}`, { note: 'private' }, answers);

  const res = await get(tier, `board=daily&rank=1&date=${CLOSED}`, answers);
  assert.equal(res.status, 403, `an unknown tier (${JSON.stringify(tier)}) read a note`);
  assert.equal((await res.json()).note, undefined, 'the refusal carried the note');

  const write = await post(tier, `board=daily&rank=1&date=${CLOSED}`, { note: 'x' }, answers);
  assert.equal(write.status, 403, `an unknown tier (${JSON.stringify(tier)}) wrote a note`);
  assert.equal(noteOf(answers, WINNER), 'private', 'a refused write reached the table');
}

// The round trip, and the shape a caller gets back from a write is the shape a
// read gives -- so nothing has to reconcile two vocabularies for one player.
{
  const answers = seeded();
  const query = `board=daily&rank=1&date=${CLOSED}`;

  const before = await (await get('production', query, answers)).json();
  assert.equal(before.note, null, 'an unnoted player came back with a note');
  assert.equal(before.name, 'Amber Basin');

  const written = await (await post('production', query, { note: 'from the stream' }, answers)).json();
  const after = await (await get('production', query, answers)).json();
  assert.deepEqual(written, after, 'a write answered differently than the read after it');
  assert.equal(after.note, 'from the stream');

  // An emptied field clears it, which is what a cleared box on either surface
  // sends -- and clearing must not be a way to lose the row's published alias.
  answers.db.prepare('UPDATE players SET alias = ? WHERE player_id = ?')
    .run('Phil', WINNER);
  const cleared = await (await post('production', query, { note: '' }, answers)).json();
  assert.equal(cleared.note, null, 'an emptied note was stored as a blank string');
  assert.equal(
    answers.db.prepare('SELECT alias FROM players WHERE player_id = ?').get(WINNER).alias,
    'Phil', 'clearing a note took down the published alias');
}

// The monthly board addresses a player too: it is the other board on screen.
{
  const answers = seeded();
  const res = await post('production', `board=monthly&rank=1&month=${CLOSED.slice(0, 7)}`,
    { note: 'monthly regular' }, answers);
  assert.equal(res.status, 200, 'a monthly board row could not be noted');
  assert.equal(noteOf(answers, WINNER), 'monthly regular');
}

// A rank the board does not reach names nobody, and must not fall through to
// whoever happens to be last.
{
  const answers = seeded();
  const res = await post('production', `board=daily&rank=9&date=${CLOSED}`, { note: 'x' }, answers);
  assert.equal(res.status, 404, 'a rank past the board was written anyway');
  assert.equal(answers.db.prepare('SELECT COUNT(*) AS n FROM players').get().n, 0,
    'a refused write left a row behind');
}

// Bad addresses and an over-long note, refused before anything is written.
for (const [query, body] of [
  ['board=weekly&rank=1', { note: 'x' }],
  ['board=daily&rank=0', { note: 'x' }],
  ['board=daily&rank=nope', { note: 'x' }],
  [`board=daily&rank=1&date=${CLOSED}`, { note: 7 }],
  [`board=daily&rank=1&date=${CLOSED}`, { note: 'x'.repeat(501) }],
]) {
  const answers = seeded();
  const res = await post('production', query, body, answers);
  assert.equal(res.status, 400, `${query} ${JSON.stringify(body)} was accepted`);
  assert.equal(answers.db.prepare('SELECT COUNT(*) AS n FROM players').get().n, 0,
    'a refused write left a row behind');
}

console.log('ok: a board row names the same player for a note as for its drilldown');
