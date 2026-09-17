// GET /admin/board-note?board=&rank=[&date=|&month=] -- the private note against
// the player in one board row. POST the same query with {note} to set it.
//
// Named for how it addresses rather than for what it holds, because /admin/notes
// is the page that edits the same column from a list: Pages answers a path no
// Function claims with the site's own HTML and a 200, so a singular/plural slip
// between the two would come back as a page pretending to be an endpoint.
//
// The same note /admin/notes edits, addressed the way the console can address a
// player at all. That surface holds no player id and is not going to start: an
// id is a write credential over there -- /api/score records under it and
// /api/link moves a whole history by it -- which is why the drilldown it already
// renders is keyed board+rank. So a note reached from a board row is reached by
// board and rank, resolved by the same atRank() the drilldown uses rather than
// by a second answer to "who is #2".
//
// Under /admin/, so it inherits the Access login the rest of the surface has --
// which is what a service token authenticates against from outside a browser.
// It has to: this is the one route that returns a note, and a note is private.
import { json, readJson } from '../_json.mjs';
import { PLACEHOLDER } from '../_names.mjs';
import { atRank } from '../api/guesses.js';
import { noteProblem, readNote, saveNote } from './_notes.mjs';
import { unknownTier } from './_tier.js';

const refusal = async (env, url) =>
  (await unknownTier(env, url))
    ? json({ error: 'player notes are not available on this tier' }, 403)
    : null;

// A note is private and a rank is a moving target, so nothing here is cacheable:
// the board it resolves against reorders as plays land, and a cached answer would
// put one player's note under another's row.
const NO_STORE = { 'cache-control': 'no-store' };

// Both verbs resolve the row the same way and answer with the same shape, so
// what comes back after a write is what a read would have returned -- a caller
// never has to reconcile two vocabularies for one player.
const resolved = async (request, env) => {
  const url = new URL(request.url);
  const refused = await refusal(env, url);
  if (refused) return { refused };

  const params = url.searchParams;
  const board = params.get('board') || 'daily';
  const { row, rank, period, error, status } = await atRank(env, board, params);
  if (error) return { refused: json({ error }, status, NO_STORE) };

  return { row, board, rank, period };
};

// The raw name, not the board's collision-numbered one -- as the drilldown does,
// and for the same reason: the numbering belongs to a rendered board, and the
// caller already holds the label it clicked. Here it doubles as the check that
// the rank still names who they meant, which matters more when the next thing
// the caller does is write.
const shape = (row, board, rank, period, note) => ({
  board, period, rank, name: row.name || PLACEHOLDER, note,
});

export async function onRequestGet({ request, env }) {
  const { refused, row, board, rank, period } = await resolved(request, env);
  if (refused) return refused;

  return json(shape(row, board, rank, period, await readNote(env, row.player_id)),
    200, NO_STORE);
}

export async function onRequestPost({ request, env }) {
  const { refused, row, board, rank, period } = await resolved(request, env);
  if (refused) return refused;

  const note = (await readJson(request))?.note ?? '';
  const problem = noteProblem(note);
  if (problem) return json({ error: problem }, 400, NO_STORE);

  return json(shape(row, board, rank, period, await saveNote(env, row.player_id, note)),
    200, NO_STORE);
}
