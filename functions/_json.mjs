// The three things every handler here does before it gets to its own job:
// answer in JSON, read a body a client may not have sent, and recognise the
// date a game is keyed on.
//
// Underscore-prefixed, so Pages leaves it out of the routing table and the
// handlers can import it -- the same arrangement _scoring.mjs and _tier.js use.

// Headers are merged rather than replaced, so a caller that wants a
// cache-control does not have to restate the content type to get one.
export const json = (body, status = 200, headers = {}) =>
  new Response(JSON.stringify(body), {
    status,
    headers: { 'content-type': 'application/json', ...headers },
  });

// The date a round set is scheduled on, YYYY-MM-DD. Shape only: the 31st of
// February matches, and parsePlay is where a date meets a real calendar.
export const DATE = /^\d{4}-\d{2}-\d{2}$/;

// A body that failed to parse comes back as null and meets the same validation
// as a well-formed one that says nothing useful -- there is nothing worth
// telling a client about which of the two it sent.
export async function readJson(request) {
  try {
    return await request.json();
  } catch {
    return null;
  }
}
