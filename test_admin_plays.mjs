// Cover /admin/plays: who may read a date's games, and whether a total can be
// trusted.
//
// Two things carry the weight. The response pairs a player id with the private
// note against it, exactly as /admin/players does, so it gets the same tier gate
// and the same test of it. And the total is the entire lookup key -- the page
// matches it against a number read off a screenshot -- so a game that arrives
// short is worse than one that does not arrive: it fails to match the player it
// belongs to, or matches one it does not.
//
// Against the real migrations over node:sqlite, so the joins are the ones that
// will run.
import assert from 'node:assert/strict';

import { d1, schema, seedAnswers } from './_d1.mjs';
import { group, onRequestGet } from './functions/admin/plays.js';

// The static-asset binding, standing in for whichever workflow deployed this
// copy -- as in test_admin_players.mjs, since it is the same question.
const assets = tier => ({
  async fetch() {
    if (tier === undefined) return new Response('nope', { status: 404 });
    if (tier === 'broken') return new Response('<html>', { status: 200 });
    return new Response(JSON.stringify({ label: 'test', tier }));
  },
});

const DATE = '2026-08-01';
const TIED_A = 'player-tied-a';
const TIED_B = 'player-tied-b';
const LOWER = 'player-lower';

const images = ['clips/a-010000.mp4', 'clips/b-020000.mp4', 'clips/c-030000.mp4'];

function seeded() {
  const answers = d1(schema());
  seedAnswers(answers.db, images);
  // `round_days.image` references `rounds`, so the pool row comes first --
  // the same order a generation run writes them in.
  const round = answers.db.prepare(
    `INSERT INTO rounds
       (image, median_km, mean_cos, batch, status, slug, source_ts_sec,
        clip_ts_sec, radius_m)
     VALUES (?, 3.1, 0.07, 'test', 'scheduled', 'trip', 20.5, 20.5, 61.2)`);
  const day = answers.db.prepare(
    'INSERT INTO round_days (date, position, image) VALUES (?, ?, ?)');
  images.forEach((image, i) => { round.run(image); day.run(DATE, i + 1, image); });

  const play = answers.db.prepare(
    `INSERT INTO plays
       (date, player_id, image, km, points, handle, played_at, guess_lat, guess_lng)
     VALUES (?, ?, ?, ?, ?, ?, '2026-08-01 10:00:00', ?, ?)`);
  // Two players on the same total and one below them. The tie is the ordinary
  // case this page exists for, not an edge one: a score is four digits and a
  // date has hundreds of games.
  play.run(DATE, TIED_A, images[0], 4.2, 3000, 'Amber Basin', 40.1, -75.1);
  play.run(DATE, TIED_A, images[1], 120.0, 2000, 'Amber Basin', 41.2, -76.2);
  play.run(DATE, TIED_B, images[0], 9.9, 4000, 'Copper Vale', 33.3, -80.3);
  play.run(DATE, TIED_B, images[1], 900.0, 1000, 'Copper Vale', 34.4, -81.4);
  play.run(DATE, LOWER, images[2], 50.0, 1500, 'Slate Harbor', null, null);
  return answers;
}

const get = (tier, answers, date = DATE) => onRequestGet({
  request: new Request(`https://stage.guessr.dana.lol/admin/plays?date=${date}`),
  env: { ANSWERS: answers, ASSETS: assets(tier) },
});

// THE ONE THAT MATTERS FOR ACCESS. Every row here carries a player id, and the
// note beside it is served by nothing on purpose -- so a deployment this code
// cannot name must not be the exception, and the refusal must carry no part of
// what it declined.
for (const tier of [undefined, 'broken', 'PRODUCTION', 'prod', '', null]) {
  const res = await get(tier, seeded());
  assert.equal(res.status, 403, `an unknown tier (${JSON.stringify(tier)}) read a date's games`);
  assert.equal((await res.json()).players, undefined,
    'the refusal carried the games it declined');
}

// A date is required and checked for shape before anything is read.
for (const date of ['', 'yesterday', '2026-8-1', '20260801']) {
  const res = await get('production', seeded(), date);
  assert.equal(res.status, 400, `${JSON.stringify(date)} was accepted as a date`);
}

// The games, on every tier that gets them.
for (const tier of ['production', 'staging', 'preview', 'local']) {
  const res = await get(tier, seeded());
  assert.equal(res.status, 200, `${tier} could not read a date's games`);
  const { date, players } = await res.json();

  assert.equal(date, DATE);
  assert.equal(players.length, 3, 'a player who played the date was missing');
  assert.deepEqual(players.map(p => p.total), [5000, 5000, 1500],
    'games were not ordered by score, highest first');
  assert.equal(res.headers.get('cache-control'), 'no-store',
    'a response carrying private notes was cacheable');
}

// The guesses, which are what separates two players on the same total -- the
// whole reason the rounds ride along rather than the totals alone.
{
  const { players } = await (await get('production', seeded())).json();
  const [a, b] = players.filter(p => p.total === 5000)
    .sort((x, y) => x.player_id.localeCompare(y.player_id));

  assert.equal(a.player_id, TIED_A);
  assert.notDeepEqual(
    a.rounds.map(r => [r.guess_lat, r.guess_lng]),
    b.rounds.map(r => [r.guess_lat, r.guess_lng]),
    'two tied games came back indistinguishable');
  // The truth beside the pin: without it a distance is a number with nothing to
  // check it against.
  assert.equal(a.rounds[0].lat, 34.0, 'a round came back without its answer');
  assert.deepEqual(a.rounds.map(r => r.position), [1, 2],
    'rounds did not arrive in the order the player saw them');
}

// A play recorded before migration 0003 has no coordinates and never will. It
// still belongs in the list -- its score is what is being looked up.
{
  const { players } = await (await get('production', seeded())).json();
  const [round] = players.find(p => p.player_id === LOWER).rounds;
  assert.equal(round.guess_lat, null, 'a play with no pin invented one');
  assert.equal(round.points, 1500, 'a play with no pin was dropped from its total');
}

// The name follows the same rule every other view uses: an alias set by hand
// wins over the handle the player drew.
{
  const answers = seeded();
  answers.db.prepare('INSERT INTO players (player_id, alias, note) VALUES (?, ?, ?)')
    .run(TIED_A, 'Phil', "Phil's roommate");
  const { players } = await (await get('production', answers)).json();
  const player = players.find(p => p.player_id === TIED_A);
  assert.equal(player.name, 'Phil', 'a published alias did not name the player');
  assert.equal(player.note, "Phil's roommate", 'the note that identifies a player was dropped');
}

// A play on an image this date never scheduled still counts. Old games sit on
// images with no round_days row, and they are the ones somebody is most likely
// to be asking about -- an inner join there would drop exactly those.
{
  const answers = seeded();
  seedAnswers(answers.db, ['clips/unscheduled-040000.mp4']);
  answers.db.prepare(
    `INSERT INTO plays (date, player_id, image, km, points, played_at)
     VALUES (?, ?, ?, 1.0, 5000, '2026-08-01 11:00:00')`)
    .run(DATE, LOWER, 'clips/unscheduled-040000.mp4');

  const { players } = await (await get('production', answers)).json();
  const player = players.find(p => p.player_id === LOWER);
  assert.equal(player.total, 6500, 'a play on an unscheduled image was left out of its total');
  assert.ok(player.rounds.some(r => r.position === null),
    'a play with no schedule row did not come back');
}

// THE OTHER ONE THAT MATTERS. group() is handed rows the LIMIT cut, and the
// player the cut landed in is dropped rather than shown short: the total is the
// lookup key, so a game missing a round is a wrong answer rather than a partial
// one -- it would fail to match the score in the screenshot, or match somebody
// else's.
{
  const rows = [
    { player_id: 'whole', name: 'A', alias: null, note: null, position: 1, image: 'x', km: 1, points: 3000, guess_lat: 1, guess_lng: 2, lat: 3, lng: 4, state: 'CA' },
    { player_id: 'whole', name: 'A', alias: null, note: null, position: 2, image: 'y', km: 1, points: 2000, guess_lat: 1, guess_lng: 2, lat: 3, lng: 4, state: 'CA' },
    { player_id: 'cut', name: 'B', alias: null, note: null, position: 1, image: 'z', km: 1, points: 4000, guess_lat: 1, guess_lng: 2, lat: 3, lng: 4, state: 'CA' },
  ];
  assert.deepEqual(group(rows, true).map(p => p.player_id), ['whole'],
    'a game cut off by the row cap was served as a total');
  // Uncapped, the same rows are three players' worth of honest games.
  assert.deepEqual(group(rows, false).map(p => p.total), [5000, 4000],
    'a complete read dropped a game anyway');
}

console.log('ok: the score lookup refuses an unknown tier, and never serves a half-counted game');
