// POST /api/report -- a player saying the round they just played was not where
// the game says it was.
//
// The value is in who is sending it: someone who recognised the street is a
// better locator than anything in make_rounds.py, and a wrong coordinate is
// otherwise invisible until Dana happens to play that round himself.
//
// A report is a message, not a record to work through later, so it goes to the
// Discord channel the rest of the fleet's reports land in and nothing here
// queues or tracks it. The one thing it does write is `plays.reported_at`,
// which is what stops the endpoint being a webhook anybody can drive (see
// migration 0005) -- so the storage that exists is the rate limit, not an
// inbox.
//
// It names the *moment*, not the clip: ground truth has been per-moment since
// guessr#81, so the correction target is the `video_coords` row keyed by
// `source_ts_sec`, and a clip-level report would be coarser than the thing a
// player was graded against.
//
// Scoring is untouched. The score a report disputes still stands, on the board
// and in the player's own history, and the reply says so -- a report that
// quietly re-scored a round would make the board a function of who complained.
import { DATE, json, readJson } from '../_json.mjs';
import { tier } from '../admin/_tier.js';

// Everything the message needs, resolved from the play rather than from what
// the browser sent: the client is trusted to name which of its own plays it
// means and nothing else. The join is LEFT for the same reason /api/guesses'
// is -- a play whose round predates the `rounds` table is still a report worth
// forwarding, it just arrives without provenance for Dana to jump to.
const DETAIL = `
  SELECT p.km, p.guess_lat, p.guess_lng, rd.position, r.slug, r.source_ts_sec
    FROM plays p
    LEFT JOIN round_days rd ON rd.date = p.date AND rd.image = p.image
    LEFT JOIN rounds r ON r.image = p.image
   WHERE p.date = ? AND p.player_id = ? AND p.image = ?`;

export async function onRequestPost({ request, env }) {
  // Before the claim below, not after: a tier with no webhook binding cannot
  // deliver a report, and marking the play reported first would burn the
  // player's one chance at it on a message nobody receives. Staging is that
  // tier today.
  if (!env.DISCORD_WEBHOOK) return json({ error: 'reports are not set up here' }, 503);

  const body = await readJson(request);
  const date = body?.date, playerId = body?.player_id, image = body?.image;
  if (!DATE.test(date ?? '') || typeof playerId !== 'string' || !playerId
      || typeof image !== 'string' || !image) {
    return json({ error: 'expected {date, player_id, image}' }, 400);
  }

  // The gate and the deduplication in one statement. A row changes only for a
  // play this player really recorded and has not already reported, so a caller
  // with no play to point at gets no further, and a caller looping on one they
  // do have sends exactly one message.
  const claim = await env.ANSWERS
    .prepare(`UPDATE plays SET reported_at = datetime('now')
               WHERE date = ? AND player_id = ? AND image = ? AND reported_at IS NULL`)
    .bind(date, playerId, image)
    .run();
  if (claim.meta.changes === 0) {
    // Two ways to change no rows, and they are a different answer to the
    // player: one has already been heard, the other is asking about a round it
    // never played. The second query only runs on this path.
    const played = await env.ANSWERS
      .prepare('SELECT 1 FROM plays WHERE date = ? AND player_id = ? AND image = ?')
      .bind(date, playerId, image)
      .first();
    return played
      ? json({ reported: true, already: true })
      : json({ error: 'that round is not one of yours' }, 403);
  }

  const row = await env.ANSWERS.prepare(DETAIL).bind(date, playerId, image).first();
  const where = await tier(env, request.url);

  const sent = await post(env.DISCORD_WEBHOOK, message(where, date, image, row));
  if (!sent) {
    // Give the claim back. The player is about to be told it didn't go through,
    // and a report held down by a Discord outage would be unreportable forever.
    await env.ANSWERS
      .prepare('UPDATE plays SET reported_at = NULL WHERE date = ? AND player_id = ? AND image = ?')
      .bind(date, playerId, image)
      .run();
    return json({ error: 'could not pass that on' }, 502);
  }

  return json({ reported: true });
}

// Which tier is talking, first and in bold, because both Pages projects post to
// the same channel: without it a staging test of this endpoint is
// indistinguishable from a player reporting a live round.
//
// The rest is what someone chasing it needs in the order they need it -- the
// round, the moment inside the source recording, and where the player thought
// it was, which is the actual evidence about where it should be.
function message(where, date, image, row) {
  const at = row?.slug
    ? `\`${row.slug}\` at ${Math.round(row.source_ts_sec)}s`
    : 'no provenance on record';
  const guess = row?.guess_lat == null
    ? 'pin not recorded'
    : `guessed ${row.guess_lat.toFixed(4)}, ${row.guess_lng.toFixed(4)}`;
  const round = row?.position ? `round ${row.position}` : 'round unscheduled';
  return `**[${where ?? 'unknown tier'}] coordinates reported** — ${date}, ${round}\n`
    + `\`${image}\` — ${at}\n`
    + `${guess}, ${Math.round(row?.km ?? 0)} km from the answer`;
}

// Delivery, as a boolean: every failure is the same failure to the caller, and
// the player is told the same thing whether Discord refused the message or
// never answered at all.
async function post(webhook, content) {
  try {
    const res = await fetch(webhook, {
      method: 'POST',
      headers: { 'content-type': 'application/json' },
      body: JSON.stringify({ content }),
    });
    return res.ok;
  } catch {
    return false;
  }
}
