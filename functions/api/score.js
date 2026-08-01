// POST /api/score -- the only place a guess becomes points, and the only place
// the true coordinates live. The client sends where it thinks the frame was and
// gets back the distance, the score, and the answer to draw on the map; the
// answers themselves reach the browser only after a guess is committed.
//
// The answers table is seeded out-of-band by `task answers:{stage,prod}:push`,
// from the answers.json that make_rounds.py writes next to the round set. So a
// deploy carrying a new round set scores nothing until that push runs -- which
// is why an unknown round is a 404 with a distinct message rather than a 500.
import { haversineKm, parseGuess, scoreFor } from '../_scoring.mjs';

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

  const answer = await env.ANSWERS
    .prepare('SELECT lat, lng, state, filmed FROM answers WHERE image = ?')
    .bind(guess.image)
    .first();
  if (!answer) return json({ error: 'unknown round' }, 404);

  const km = haversineKm(guess, answer);
  // ponytail: stateless, so nothing stops a client scoring the same round twice
  // and keeping the better number. That is fine while the score is only ever
  // shown back to the player who made it; a leaderboard needs a per-player,
  // per-round record, which is the D1 table the leaderboard work adds anyway.
  return json({
    km,
    points: scoreFor(km),
    lat: answer.lat,
    lng: answer.lng,
    state: answer.state,
    filmed: answer.filmed,
  });
}
