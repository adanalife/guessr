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
// schedule, then recorded once in `plays`. A guess with no date is
// a practice round -- scored, never stored, and only against a round from a day
// that is over, because that is all practice ever deals.
import { haversineKm, isPlay, parseGuess, parsePlay, scoreFor } from '../_scoring.mjs';
// Only the play window. The draw is a table, but both sides still have to agree
// on when a date is open, and that is a rule about clocks rather than data -- so
// it stays code, and stays shared.
import { isOpen, lastClosedDate } from '../../web/daily.js';
import { json, readJson } from '../_json.mjs';

export async function onRequestPost({ request, env }) {
  // A malformed payload is a 400 below, same as a well-formed one that fails
  // parseGuess -- there is nothing useful to tell a client about which.
  const body = await readJson(request);

  const guess = parseGuess(body);
  if (!guess) return json({ error: 'expected {image, lat, lng}' }, 400);

  // Rejected rather than ignored: a play that means to be recorded and is
  // malformed would otherwise score normally and quietly never reach the board,
  // which the player has no way to see.
  const play = parsePlay(body);
  if (isPlay(body) && !play) return json({ error: 'expected {date, player_id}' }, 400);

  // What stops a posted play being invented rather than earned: a play has to
  // name a date that is open, and a round that date actually plays. Without
  // both, any image name a script has seen buys whatever score it likes on any
  // date, including ones nobody has reached yet.
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

  // The response carries the answer, so an undated guess at a round some date
  // has yet to finish -- today's, or one still to come -- would read that
  // round's truth before a single daily guess had been committed. Practice only
  // deals rounds from closed dates (/api/day?practice), so that is all it may
  // score.
  if (!play && !(await practiceable(env, guess.image))) {
    return json({ error: 'that round is not open to practice' }, 403);
  }

  const km = haversineKm(guess, answer);
  const scored = { km, points: scoreFor(km) };
  const truth = {
    lat: answer.lat,
    lng: answer.lng,
    state: answer.state,
    filmed: answer.filmed,
  };

  const reveal = await nearestReveal(env, guess);

  if (!play) return json({ ...scored, ...truth, reveal, recorded: false });

  const { km: keptKm, points: keptPoints } = await record(env, play, guess, scored);
  // The truth goes back either way: a replay has already committed a guess for
  // this round once, so it is not learning anything it wasn't told the first
  // time -- and the page needs it to draw the map.
  return json({ km: keptKm, points: keptPoints, ...truth, reveal, recorded: true });
}

// How far from a pin the nearest still may be and still be "what your guess
// looks like". Past this the pin is off every road the van drove, and a frame
// 60 km away is a picture of somewhere else.
export const REVEAL_KM = 25;
const KM_PER_DEG = 111.2;

// The corpus frame nearest the guess, or null when there is none within
// REVEAL_KM. The pin rather than the answer, and after the answer lookup: a
// still of where the player *guessed* tells them nothing about the round, and
// the order keeps an unknown round a 404 rather than a wasted query.
//
// A latitude band on the index, a longitude window on what is left, then the
// nearest by flat-earth distance -- which is exact enough to rank points 25 km
// apart, with haversine on the one winner for the number the page shows.
export async function nearestReveal(env, guess) {
  const dLat = REVEAL_KM / KM_PER_DEG;
  const cos = Math.max(Math.cos(guess.lat * Math.PI / 180), 0.01);
  const dLng = dLat / cos;
  // Any failure is no reveal rather than a failed guess: the still is decoration
  // on a score that has already been earned, and a tier whose migrations are
  // behind its deploy has no table to read at all.
  let row;
  try {
    row = await env.ANSWERS
      .prepare(`SELECT image, lat, lng FROM reveals
                WHERE lat BETWEEN ? AND ? AND lng BETWEEN ? AND ?
                ORDER BY (lat - ?) * (lat - ?) + (lng - ?) * (lng - ?) * ?
                LIMIT 1`)
      .bind(guess.lat - dLat, guess.lat + dLat, guess.lng - dLng, guess.lng + dLng,
        guess.lat, guess.lat, guess.lng, guess.lng, cos * cos)
      .first();
  } catch {
    return null;
  }
  if (!row) return null;
  const km = haversineKm(guess, row);
  if (km > REVEAL_KM) return null;
  return { image: `reveals/${row.image}`, lat: row.lat, lng: row.lng, km };
}

// Whether an image is one of the five that date plays. The property this has to
// hold is "the rounds scored against are provably the rounds the page handed
// out", and reading the schedule gets it outright: there is one row set, both
// sides read it, and a deploy cannot come into it at all.
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

// Whether an image is one practice could have dealt: scheduled on a date that
// has closed. The same predicate as /api/day?practice, so a round is scoreable
// undated exactly when it is drawable undated. round_days_once makes it a
// one-row index lookup.
async function practiceable(env, image) {
  const row = await env.ANSWERS
    .prepare('SELECT 1 FROM round_days WHERE image = ? AND date <= ?')
    .bind(image, lastClosedDate())
    .first();
  return row !== null;
}

// Writes the play, and returns whatever ended up on record -- the new score if
// this is the first time this player has answered this round on this date, the
// stored one if it isn't. First write wins, so re-scoring a round cannot improve
// what the board sees.
//
// The pin goes in beside the distance it earned, because km cannot be turned
// back into it -- a radius is not a point -- and where a guess went is the half
// of a result worth looking at again. Only for a recorded play: a practice round
// writes nothing at all, so there is nothing to put coordinates on.
//
// ponytail: two statements rather than one INSERT ... RETURNING, because D1's
// `changes` is the reliable way to tell an insert from an ignored conflict and
// the second query only runs on the replay path.
async function record(env, play, guess, scored) {
  const insert = await env.ANSWERS
    .prepare(`INSERT INTO plays (date, player_id, image, km, points, handle, guess_lat, guess_lng)
              VALUES (?, ?, ?, ?, ?, ?, ?, ?)
              ON CONFLICT (date, player_id, image) DO NOTHING`)
    .bind(play.date, play.playerId, guess.image, scored.km, scored.points, play.handle,
      guess.lat, guess.lng)
    .run();
  if (insert.meta.changes > 0) return scored;

  const kept = await env.ANSWERS
    .prepare('SELECT km, points FROM plays WHERE date = ? AND player_id = ? AND image = ?')
    .bind(play.date, play.playerId, guess.image)
    .first();
  // A conflict means the row is there, so a miss here is a database that changed
  // under the request. Returning the fresh score beats failing the round.
  return kept || scored;
}
