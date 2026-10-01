// Cover the shared recap: /api/games hands a player links to their own finished
// days, /api/recap turns one of those links back into the game it names.
//
// Three things here fail quietly, and they are the reason this file exists.
//
// The token is the whole access rule, and a hash that stopped depending on the
// date -- or on the player -- would still round-trip perfectly through the
// endpoint that made it. Nothing would look wrong until a link to one game
// opened another.
//
// The closing gate is the only thing standing between a shared link and a
// spoiler. A recap is five answers on a map, so serving one for a day still in
// play hands them to whoever opens it, which is the person least likely to have
// asked.
//
// And a player id must not be derivable from anything either endpoint returns.
// It is the credential /api/link merges histories on, and a recap link exists to
// be forwarded to strangers.
//
// Against the real migrations over node:sqlite, so the queries are the ones that
// will run.
import assert from 'node:assert/strict';

import { d1, post, schema } from './_d1.mjs';
import { onRequestGet } from './functions/api/recap.js';
import { onRequestPost } from './functions/api/games.js';
import { tokenFor } from './functions/_recap.mjs';
import { lastClosedDate } from './web/daily.js';

const env = { ANSWERS: d1(schema()) };

// Two closed dates and one still being played. Derived from the closing rule
// rather than written down, because the rule is what decides which of these the
// endpoint will serve -- fixed dates would pass today and start failing on their
// own schedule.
const CLOSED = lastClosedDate();
const EARLIER = new Date(Date.parse(`${CLOSED}T00:00:00Z`) - 86400000)
  .toISOString().slice(0, 10);
const OPEN = new Date(Date.parse(`${CLOSED}T00:00:00Z`) + 86400000 * 2)
  .toISOString().slice(0, 10);

const image = (date, i) => `clips/${date.replaceAll('-', '')}-${i}.mp4`;

let n = 0;
function seed(date, plays) {
  for (const i of [1, 2, 3, 4, 5]) {
    const img = image(date, i);
    env.ANSWERS.db
      .prepare(`INSERT INTO rounds (image, median_km, mean_cos, batch, slug,
                                    source_ts_sec, clip_ts_sec, radius_m)
                VALUES (?, ?, 0.07, 'test', 'slug', 20, 20, 60)`)
      .run(img, ++n * 10);
    env.ANSWERS.db
      .prepare('INSERT INTO round_days (date, position, image) VALUES (?, ?, ?)')
      .run(date, i, img);
    // A distinct answer per round, so a handler that returned the same one five
    // times would be caught rather than looking plausible.
    env.ANSWERS.db
      .prepare('INSERT INTO answers (image, lat, lng, state, filmed) VALUES (?, ?, ?, ?, ?)')
      .run(img, 40 + i, -100 - i, 'Kansas', '2018-05-0' + i);
  }
  for (const [player, rounds, handle] of plays) {
    for (const [i, p] of rounds) {
      env.ANSWERS.db
        .prepare(`INSERT INTO plays (date, player_id, image, km, points, handle,
                                     guess_lat, guess_lng)
                  VALUES (?, ?, ?, ?, ?, ?, ?, ?)`)
        .run(date, player, image(date, i), 12.5, p, handle,
          p === null ? null : 41 + i, p === null ? null : -101 - i);
    }
  }
}

// phil finishes both closed days and the open one; nyx plays one of them, so
// that "the rounds this player answered" is never the same set as "the rounds
// that date schedules".
const FIVE = [[1, 4000], [2, 3000], [3, 2000], [4, 1000], [5, 500]];
seed(EARLIER, [['phil', FIVE, 'Amber Basin']]);
seed(CLOSED, [['phil', FIVE, 'Amber Basin'], ['nyx', [[1, 4900], [2, 100]], 'Dusty Lookout']]);
seed(OPEN, [['phil', FIVE, 'Amber Basin']]);

const games = player => onRequestPost({ request: post({ player_id: player }), env })
  .then(async res => [res.status, await res.json()]);

const recap = query => onRequestGet({
  request: new Request(`https://guessr.dana.lol/api/recap?${query}`),
  env,
}).then(async res => [res.status, await res.json()]);

// A player's own list: every day they played, newest first, with a link only to
// the ones that have finished playing.
{
  const [status, json] = await games('phil');
  assert.equal(status, 200);
  assert.deepEqual(json.games.map(g => g.date), [OPEN, CLOSED, EARLIER],
    'games did not come back newest first');
  assert.deepEqual(json.games.map(g => [g.total, g.rounds]),
    [[10500, 5], [10500, 5], [10500, 5]]);

  // The open day is listed -- it was played and it counted -- and carries no
  // token, which is what the page turns into how long the wait is.
  assert.equal(json.games[0].token, null, 'an open day was handed a share link');
  assert.ok(json.games[1].token, 'a closed day was not given a share link');

  // The list is keyed on a credential, so nothing in it may be one.
  assert.ok(!JSON.stringify(json).includes('phil'), 'the player id came back in its own listing');
}

// A short game is listed as a short game. Its total is real and its round count
// is what makes the total readable.
{
  const [, json] = await games('nyx');
  assert.deepEqual(json.games.map(g => [g.date, g.total, g.rounds]), [[CLOSED, 5000, 2]]);
}

// A player nobody has heard of gets an empty list rather than an error: an id
// that has never recorded a play is the ordinary state of a new browser.
{
  const [status, json] = await games('nobody');
  assert.deepEqual([status, json], [200, { games: [] }]);
}

// The id has to be an id. Without this the endpoint would answer an empty list
// for a malformed request, which reads to a caller as "you have played nothing".
for (const body of [{}, { player_id: '' }, { player_id: 42 }, undefined]) {
  const [status] = await onRequestPost({ request: post(body), env })
    .then(async res => [res.status, await res.json()]);
  assert.equal(status, 400, `${JSON.stringify(body)} was accepted as a player`);
}

console.log('ok: a player gets their own finished days, and links to the closed ones');

// The round trip: the link /api/games hands out opens the game it was made for.
{
  const [, { games: list }] = await games('phil');
  const { date, token } = list.find(g => g.date === CLOSED);
  const [status, json] = await recap(`date=${date}&r=${token}`);

  assert.equal(status, 200);
  assert.equal(json.date, CLOSED);
  assert.equal(json.name, 'Amber Basin');
  assert.equal(json.total, 10500);

  // In the order the day plays them, which is what makes the numbers on the map
  // match the numbers on the contact sheet. Nothing downstream re-sorts these.
  assert.deepEqual(json.rounds.map(r => r.image),
    [1, 2, 3, 4, 5].map(i => image(CLOSED, i)));
  assert.deepEqual(json.rounds.map(r => r.points), [4000, 3000, 2000, 1000, 500]);

  // Both ends of every line: where the pin went and where the answer was. The
  // guess coordinates are the entire reason this endpoint exists, and they are
  // not recoverable from km -- a distance is a radius, not a point.
  assert.deepEqual(json.rounds.map(r => [r.guess_lat, r.guess_lng]),
    [[42, -102], [43, -103], [44, -104], [45, -105], [46, -106]]);
  assert.deepEqual(json.rounds.map(r => [r.lat, r.lng]),
    [[41, -101], [42, -102], [43, -103], [44, -104], [45, -105]]);

  assert.ok(!JSON.stringify(json).includes('phil'), 'the recap gave away the player id');
}

// A recap shows the game its player actually had. nyx answered two of the five,
// so a recap of that day is two rounds -- not five with three blanks, and not
// somebody else's rounds filling the gap.
{
  const [, { games: list }] = await games('nyx');
  const [status, json] = await recap(`date=${CLOSED}&r=${list[0].token}`);
  assert.equal(status, 200);
  assert.equal(json.name, 'Dusty Lookout');
  assert.deepEqual(json.rounds.map(r => r.points), [4900, 100]);
}

// An operator alias reaches a recap too. The board and the recap of the same day
// disagreeing about who played it is the failure the shared name expression
// exists to prevent, so it is worth one assertion on each side of it.
{
  env.ANSWERS.db.prepare('INSERT INTO players (player_id, alias) VALUES (?, ?)')
    .run('phil', 'Phil');
  const [, json] = await recap(`date=${CLOSED}&r=${await tokenFor('phil', CLOSED)}`);
  assert.equal(json.name, 'Phil');
  env.ANSWERS.db.prepare('DELETE FROM players WHERE player_id = ?').run('phil');
}

console.log('ok: a link opens the game it names, both ends of every guess intact');

// A day still being played is refused, with the time it closes rather than only
// the fact that it is early. This is the spoiler gate: everything the endpoint
// returns is an answer key.
{
  const [status, json] = await recap(`date=${OPEN}&r=${await tokenFor('phil', OPEN)}`);
  assert.equal(status, 403);
  assert.ok(json.closes > Date.now(), 'the refusal did not say when the day closes');
  assert.ok(!json.rounds, 'a refusal carried the rounds anyway');
}

// A token is good for one game, not for a player. Sharing a result must not hand
// over every other day that player has finished.
{
  const wrong = await tokenFor('phil', EARLIER);
  const [status] = await recap(`date=${CLOSED}&r=${wrong}`);
  assert.equal(status, 404, "a token for one date opened another date's game");
}

// And it names one player, not one date: nyx's token must not open phil's game
// on the day they both played.
{
  const [status, json] = await recap(`date=${CLOSED}&r=${await tokenFor('nyx', CLOSED)}`);
  assert.equal(json.name, 'Dusty Lookout', "one player's token opened another's game");
  assert.equal(status, 200);
}

// Every other way a link can be wrong is one 404, and none of them says which.
// A reader can do nothing about any of them but ask for the link again, and
// telling them apart would say whether a given player played a given day.
for (const r of ['', 'not-hex', '00', 'f'.repeat(12), 'F'.repeat(12), `${await tokenFor('nyx', CLOSED)}0`]) {
  const [status] = await recap(`date=${EARLIER}&r=${encodeURIComponent(r)}`);
  assert.equal(status, 404, `"${r}" was accepted as a token`);
}

// A malformed date never reaches the lookup: it is the cache key and the gate
// input both, and "yesterday" is not a date this game has.
for (const date of ['', 'yesterday', '2026-8-1', '2026-08-01T00:00:00Z']) {
  const [status] = await recap(`date=${encodeURIComponent(date)}&r=${'0'.repeat(12)}`);
  assert.equal(status, 400, `"${date}" was accepted as a date`);
}

console.log('ok: a link opens one game, and only after that game has closed');

// The token itself: what it depends on, and what it gives away. The endpoints
// above would pass with a hash of the player alone, which is exactly the bug
// that turns one shared link into a key to everything.
{
  const a = await tokenFor('phil', CLOSED);
  assert.equal(a, await tokenFor('phil', CLOSED), 'the token is not stable');
  assert.notEqual(a, await tokenFor('phil', EARLIER), 'the token ignores the date');
  assert.notEqual(a, await tokenFor('nyx', CLOSED), 'the token ignores the player');
  assert.match(a, /^[0-9a-f]{12}$/);

  // The separator is not decorative: without it `date:player` collides with any
  // other split of the same characters, so two different players could share a
  // token on two different dates.
  assert.notEqual(await tokenFor('a', '2026-08-01b'), await tokenFor('b', '2026-08-01a'),
    'the token concatenates without a boundary');
}

console.log('ok: a token names one player on one date, and cannot be read backwards');
