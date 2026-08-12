// Every request either page makes, so that none of them can hang.
//
// A fetch has no timeout of its own. A connection that goes away without
// closing -- a phone leaving wifi, a laptop waking from sleep, a NAT dropping
// the flow -- leaves the promise pending rather than rejecting it, and each
// await in the game is somewhere a promise that never settles strands a piece
// of it: the round being scored, the game being loaded, the devices being
// linked, the day an operator is looking at. Every one of those callers already
// handles a request that failed. None of them can handle one that neither fails
// nor succeeds, so the deadline is what turns the second kind into the first.
//
// In its own module for the reason zoom.js and daily.js are: it can be checked
// in node, which is where the deadline is worth checking, since a stalled
// connection is the one condition a browser won't reproduce on demand.

// One number for every endpoint, and a generous one. They are single indexed
// lookups, so this is not a limit any of them approach on a working connection
// -- it is the point past which a connection is not working, and the
// alternative to waiting is telling a player their good guess didn't count.
export const TIMEOUT_MS = 15000;

// An abort rejects with a TimeoutError, which is a failed request as far as
// every caller is concerned -- none of them branch on which kind it was, and
// the one that puts a message on screen supplies its own wording rather than
// repeating the browser's.
//
// The deadline is a parameter of the factory rather than read from the constant
// inside, so that what a deadline does can be checked against a server that
// stalls without the check itself having to wait out the real one.
export const withDeadline = ms => (url, opts = {}) =>
  fetch(url, { ...opts, signal: AbortSignal.timeout(ms) });

export const request = withDeadline(TIMEOUT_MS);
