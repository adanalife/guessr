// Cover /admin/players: who may read the list, and what a note write may touch.
//
// Two things carry the weight. The list is the only response in this codebase
// that returns a player id beside a private note, so the tier gate on it is the
// same gate the day preview has and is tested the same way. And the write sets
// one column: the alias beside it is published, and a save here taking one down
// would be invisible until somebody noticed the overlay had gone back to a
// wordlist pair.
//
// Against the real migrations over node:sqlite, so the join and the upsert are
// the ones that will run.
import assert from 'node:assert/strict';

import { d1, schema, seedAnswers } from './_d1.mjs';
import { onRequestGet, onRequestPost } from './functions/admin/players.js';

// The static-asset binding, standing in for whichever workflow deployed this
// copy -- as in test_admin_day.mjs, since it is the same question.
const assets = tier => ({
  async fetch() {
    if (tier === undefined) return new Response('nope', { status: 404 });
    if (tier === 'broken') return new Response('<html>', { status: 200 });
    return new Response(JSON.stringify({ label: 'test', tier }));
  },
});

const REGULAR = 'player-regular';
const NEWCOMER = 'player-newcomer';

function seeded() {
  const answers = d1(schema());
  const images = ['clips/a-010000.mp4', 'clips/b-020000.mp4', 'clips/c-030000.mp4'];
  seedAnswers(answers.db, images);
  const play = answers.db.prepare(
    `INSERT INTO plays (date, player_id, image, km, points, handle, played_at)
     VALUES (?, ?, ?, 10.0, ?, ?, ?)`);
  // Two days for the regular, one for the newcomer, and the newcomer played
  // most recently -- so an ordering that fell back to insertion order or to
  // points comes out wrong rather than coincidentally right.
  play.run('2026-08-01', REGULAR, images[0], 4000, 'Amber Basin', '2026-08-01 10:00:00');
  play.run('2026-08-02', REGULAR, images[1], 3000, 'Amber Basin', '2026-08-02 10:00:00');
  play.run('2026-08-03', NEWCOMER, images[2], 100, 'Copper Vale', '2026-08-03 10:00:00');
  return answers;
}

const get = (tier, answers) => onRequestGet({
  request: new Request('https://stage.guessr.dana.lol/admin/players'),
  env: { ANSWERS: answers, ASSETS: assets(tier) },
});

const post = (tier, body, answers) => onRequestPost({
  request: new Request('https://stage.guessr.dana.lol/admin/players',
    { method: 'POST', body: JSON.stringify(body) }),
  env: { ANSWERS: answers, ASSETS: assets(tier) },
});

// THE ONE THAT MATTERS. A note is served by nothing on purpose, so a deployment
// this code cannot name must not be the exception -- and the refusal must carry
// no part of the list it declined.
for (const tier of [undefined, 'broken', 'PRODUCTION', 'prod', '', null]) {
  const answers = seeded();
  const res = await get(tier, answers);
  assert.equal(res.status, 403, `an unknown tier (${JSON.stringify(tier)}) read the players`);
  assert.equal((await res.json()).players, undefined,
    'the refusal carried the list it declined');

  const write = await post(tier, { player_id: REGULAR, note: 'leaked' }, answers);
  assert.equal(write.status, 403, `an unknown tier (${JSON.stringify(tier)}) wrote a note`);
  assert.equal(
    answers.db.prepare('SELECT COUNT(*) AS n FROM players').get().n, 0,
    'a refused write reached the table anyway');
}

// The list, on every tier that gets one. Production included: its players are
// the ones worth recognising.
for (const tier of ['production', 'staging', 'preview', 'local']) {
  const res = await get(tier, seeded());
  assert.equal(res.status, 200, `${tier} could not read the players`);
  const { players } = await res.json();

  assert.deepEqual(players.map(p => p.player_id), [NEWCOMER, REGULAR],
    'the list was not ordered by who played most recently');
  assert.equal(players[1].days, 2, 'a player was not counted across their days');
  assert.equal(players[1].points, 7000, 'points did not sum across a player');
  assert.equal(players[1].name, 'Amber Basin', 'a player came back without their name');
  assert.equal(players[1].note, null, 'an unnamed player came back with a note');
  assert.equal(res.headers.get('cache-control'), 'no-store',
    'a response carrying private notes was cacheable');
}

// The round trip: a note goes in, and comes back on the next read.
{
  const answers = seeded();
  const res = await post('production', { player_id: REGULAR, note: "Phil's roommate" }, answers);
  assert.equal(res.status, 200, 'a note would not save');
  assert.equal((await res.json()).note, "Phil's roommate");

  const [regular] = (await (await get('production', answers)).json())
    .players.filter(p => p.player_id === REGULAR);
  assert.equal(regular.note, "Phil's roommate", 'a saved note did not come back');
  // Still their own name: a note is private and changes nothing anybody sees.
  assert.equal(regular.name, 'Amber Basin', 'a note changed what a player is called');
}

// An empty note clears it rather than storing a blank, which is what an emptied
// field on the page sends.
{
  const answers = seeded();
  await post('production', { player_id: REGULAR, note: 'temporary' }, answers);
  await post('production', { player_id: REGULAR, note: '' }, answers);
  assert.equal(
    answers.db.prepare('SELECT note FROM players WHERE player_id = ?').get(REGULAR).note,
    null, 'an emptied note was stored as a blank string');
}

// THE OTHER ONE THAT MATTERS. The alias is published and this page does not edit
// it, so a note write must leave it exactly where it was -- including when the
// row is created by a note and when the note is later cleared.
{
  const answers = seeded();
  answers.db.prepare('INSERT INTO players (player_id, alias) VALUES (?, ?)')
    .run(REGULAR, 'Phil');

  await post('production', { player_id: REGULAR, note: 'met at the meetup' }, answers);
  let row = answers.db.prepare('SELECT alias, note FROM players WHERE player_id = ?')
    .get(REGULAR);
  assert.equal(row.alias, 'Phil', 'saving a note took down the published alias');
  assert.equal(row.note, 'met at the meetup');

  await post('production', { player_id: REGULAR, note: '' }, answers);
  row = answers.db.prepare('SELECT alias FROM players WHERE player_id = ?').get(REGULAR);
  assert.equal(row.alias, 'Phil', 'clearing a note took down the published alias');

  // And the alias still wins where a name renders, which is the whole reason it
  // must survive: the list is where you would notice it had not.
  const [regular] = (await (await get('production', answers)).json())
    .players.filter(p => p.player_id === REGULAR);
  assert.equal(regular.name, 'Phil', 'the published alias stopped naming the player');
  assert.equal(regular.alias, 'Phil', 'the list did not say a name was published');
}

// A player id nobody has played under is a typo or a stale copy. Writing it
// would leave a row this page can never show again, since it lists players by
// their plays.
{
  const answers = seeded();
  const res = await post('production', { player_id: 'nobody', note: 'x' }, answers);
  assert.equal(res.status, 404, 'a note was written against a player who never played');
  assert.equal(answers.db.prepare('SELECT COUNT(*) AS n FROM players').get().n, 0,
    'a refused write left a row behind');
}

// Malformed bodies, and a note past the cap.
for (const body of [{}, { player_id: '' }, { player_id: 42 }, { player_id: REGULAR, note: 7 }]) {
  const res = await post('production', body, seeded());
  assert.equal(res.status, 400, `${JSON.stringify(body)} was accepted`);
}
{
  const answers = seeded();
  const res = await post('production', { player_id: REGULAR, note: 'x'.repeat(501) }, answers);
  assert.equal(res.status, 400, 'a runaway paste was stored as a note');
  assert.equal(answers.db.prepare('SELECT COUNT(*) AS n FROM players').get().n, 0,
    'an over-long note reached the table');
}

console.log('ok: the player list refuses an unknown tier, and a note leaves the alias alone');
