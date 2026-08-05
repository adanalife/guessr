// POST /api/score -- the only place a guess becomes points, and the only place
// the true coordinates live. The client sends where it thinks the frame was and
// gets back the distance, the score, and the answer to draw on the map; the
// answers themselves reach the browser only after a guess is committed.
//
// The answers table is seeded out-of-band by `task answers:{stage,prod}:push`,
// from the answers.json that make_rounds.py writes next to the round set. So a
// round set scores nothing until that push runs -- which is why an unknown round
// is a 404 with a distinct message rather than a 500.
// A guess that names a date is a daily play: checked against that date's
// schedule, then recorded once in `plays` (schema.sql). A guess with no date is
// a practice round -- scored, never stored, never checked, because nothing is at
// stake.
import { haversineKm, isPlay, parseGuess, parsePlay, scoreFor } from '../_scoring.mjs';
// Only the play window, now that the draw is a table. Both sides still have to
// agree on when a date is open, and that is a rule about clocks rather than data
// -- so it stays code, and stays shared.
import { isOpen } from '../../web/daily.js';

const json = (body, status = 200) =>
  new Response(JSON.stringify(body), {
    status,
    headers: { 'content-type': 'application/json' },
  });

export async function onRequestPost({ request, env }) {
  let body = null;
  // A malformed payload is a 400 below, same as a well-formed one that fails
  // parseGuess -- there is nothing useful to tell a client about which.
  try {
    body = await request.json();
  } catch { /* body stays null */ }

  const guess = parseGuess(body);
  if (!guess) return json({ error: 'expected {image, lat, lng}' }, 400);

  // Rejected rather than ignored: a play that means to be recorded and is
  // malformed would otherwise score normally and quietly never reach the board,
  // which the player has no way to see.
  const play = parsePlay(body);
  if (isPlay(body) && !play) return json({ error: 'expected {date, player_id}' }, 400);

  // What stops a posted play being invented rather than earned. The draw is
  // deterministic and runs on the client, so without these two a script can work
  // out any date's five -- including next week's -- and post whatever score it
  // likes against them.
  //
  // Both are 403 rather than 400: the request is perfectly well formed, it is
  // just not a play this endpoint will accept, and the page tells them apart from
  // a malformed one to know it must not retry.
  if (play && !isOpen(play.date)) {
    return json({ error: 'that day is closed' }, 403);
  }
  if (play && !(await inDraw(env, play.date, guess.image))) {
    return json({ error: 'that round is not in that day\'s game' }, 403);
  }

  const answer = await env.ANSWERS
    .prepare('SELECT lat, lng, state, filmed FROM answers WHERE image = ?')
    .bind(guess.image)
    .first();
  if (!answer) return json({ error: 'unknown round' }, 404);

  const km = haversineKm(guess, answer);
  const scored = { km, points: scoreFor(km) };
  const truth = {
    lat: answer.lat,
    lng: answer.lng,
    state: answer.state,
    filmed: answer.filmed,
  };

  if (!play) return json({ ...scored, ...truth, recorded: false });

  const { km: keptKm, points: keptPoints } = await record(env, play, guess.image, scored);
  // The truth goes back either way: a replay has already committed a guess for
  // this round once, so it is not learning anything it wasn't told the first
  // time -- and the page needs it to draw the map.
  return json({ km: keptKm, points: keptPoints, ...truth, recorded: true });
}

// Whether an image is one of the five that date plays. The property this has to
// hold is "the rounds scored against are provably the rounds the page handed
// out", and reading the schedule is a stronger way to get it than recomputing
// the draw was: that relied on the page and this handler being bundled from one
// commit, so a half-finished deploy could break it. Now there is one row set and
// both sides read it, and a deploy cannot come into it at all.
//
// The primary key is (date, position), so this is an index scan on date and a
// look at five rows.
async function inDraw(env, date, image) {
  const row = await env.ANSWERS
    .prepare('SELECT 1 FROM round_days WHERE date = ? AND image = ?')
    .bind(date, image)
    .first();
  return row !== null;
}

// Writes the play, and returns whatever ended up on record -- the new score if
// this is the first time this player has answered this round on this date, the
// stored one if it isn't. First write wins, so re-scoring a round cannot improve
// what the board sees.
//
// ponytail: two statements rather than one INSERT ... RETURNING, because D1's
// `changes` is the reliable way to tell an insert from an ignored conflict and
// the second query only runs on the replay path.
async function record(env, play, image, scored) {
  const insert = await env.ANSWERS
    .prepare(`INSERT INTO plays (date, player_id, image, km, points, handle)
              VALUES (?, ?, ?, ?, ?, ?)
              ON CONFLICT (date, player_id, image) DO NOTHING`)
    .bind(play.date, play.playerId, image, scored.km, scored.points, play.handle)
    .run();
  if (insert.meta.changes > 0) return scored;

  const kept = await env.ANSWERS
    .prepare('SELECT km, points FROM plays WHERE date = ? AND player_id = ? AND image = ?')
    .bind(play.date, play.playerId, image)
    .first();
  // A conflict means the row is there, so a miss here is a database that changed
  // under the request. Returning the fresh score beats failing the round.
  return kept || scored;
}
