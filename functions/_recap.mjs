// The token in a recap link: what identifies whose game is being shown, without
// being the thing that could play as them.
//
// A player id cannot go in a shared URL. It is the only credential this game has
// -- /api/link takes one and hands over a whole history, /api/score posts plays
// as its holder -- and a link exists to be forwarded, pasted into a chat, and
// read by everyone in it. So the URL carries a one-way hash of the id instead:
// enough to find the player again, useless for being them.
//
// Salted with the date, so a token names one game rather than a person. Sharing
// yesterday's result would otherwise hand over a key to every other day that
// player has ever finished, including the ones they did badly at.
//
// Truncated to six bytes. It is a lookup key rather than a secret protecting
// anything -- what it unlocks is a score somebody chose to publish -- and 48
// bits is far past guessing at HTTP speeds, while a full digest makes a link too
// long to read.
//
// Underscore-prefixed, so Pages leaves it out of the routing table.

const BYTES = 6;

export async function tokenFor(playerId, date) {
  const input = new TextEncoder().encode(`${date}:${playerId}`);
  const digest = await crypto.subtle.digest('SHA-256', input);
  return [...new Uint8Array(digest).slice(0, BYTES)]
    .map(b => b.toString(16).padStart(2, '0'))
    .join('');
}

export const TOKEN = new RegExp(`^[0-9a-f]{${BYTES * 2}}$`);

// The reverse, which a hash cannot do directly: hash every player who has a game
// on that date and see which one matches. Null when none does -- a mistyped
// link, or a token for a date its player never played.
//
// ponytail: linear in that date's players, which is tens. The alternative is
// storing the token as a column, and that is the change to make if a day ever
// draws thousands -- the token is derived, so a stored one can be backfilled
// from this same function.
export async function playerFor(env, date, token) {
  if (!TOKEN.test(token)) return null;
  const { results } = await env.ANSWERS
    .prepare('SELECT DISTINCT player_id FROM plays WHERE date = ?')
    .bind(date)
    .all();
  for (const { player_id: id } of results) {
    if (await tokenFor(id, date) === token) return id;
  }
  return null;
}
