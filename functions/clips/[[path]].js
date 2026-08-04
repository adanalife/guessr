// GET /clips/<slug>.mp4 -- a round's footage, streamed straight out of R2.
//
// The media has always travelled through R2 rather than git: a round set is
// ~150 MB of mp4 and this is a public repo, so committing one would add that to
// history on every regeneration, permanently. What changed is how it arrives. It
// used to come as a tarball that each deploy unpacked into web/, which made the
// clips *deployed assets* -- and that is what made a round set something only a
// deploy could change, because the tarball is named after a hash of the committed
// manifest. Serving the media from here instead is the prerequisite for
// publishing a round set without a deploy at all.
//
// Three things this buys immediately, before any of that lands:
//
//   - The ~125 MB pull comes out of all three deploy workflows.
//   - A regeneration stops having to be pushed as one object. `rounds:rebuild`
//     can replace a single clip.
//   - The bucket stays private and reachable only through this binding, so
//     nothing enumerates it -- which is what keeps the licence and bystander
//     questions about publishing dashcam frames answerable.
//
// The cost is that clips now count against the Functions request budget where a
// static asset did not: 100k/day on the free tier, about 9,000 plays. That is
// three orders of magnitude above current traffic and the fix at the ceiling is
// the $5 Workers plan, not a redesign. An R2 custom domain would take clips off
// the budget entirely and needs dana.lol on a Cloudflare zone, which is tracked
// separately.

// A filename carrying the moment it was cut from -- `<slug>-<milliseconds>.mp4`
// -- can only ever mean one three seconds of footage, so it is safe to cache
// forever. A bare `<slug>.mp4` is not: a regeneration picking a different moment
// from the same clip would put different footage behind a URL somebody already
// holds. Round sets built before the moment was part of the name therefore get an
// hour, and the set that replaces them gets a year without this having to change.
const MOMENT_IN_NAME = /-\d{6,}\.mp4$/;
const YEAR = 31536000;
const HOUR = 3600;

export async function onRequest({ request, params, env }) {
  // HEAD is served by the same path: the runtime drops the body, and a separate
  // .head() branch would be a second thing to keep correct for no gain.
  if (request.method !== 'GET' && request.method !== 'HEAD') {
    return new Response(null, { status: 405, headers: { allow: 'GET, HEAD' } });
  }

  const name = [].concat(params.path ?? []).join('/');
  // R2 keys are a flat namespace rather than paths, so `..` in a name is a
  // literal that simply misses -- there is nothing to traverse. This is here to
  // keep the endpoint to one job, not as a boundary check.
  if (!name.endsWith('.mp4')) return new Response(null, { status: 404 });

  // R2 parses Range and the conditional headers itself, which is why the whole
  // Headers object goes in rather than a hand-rolled byte range. Seeking within a
  // clip is a real request the player makes -- the frame zoom pauses and scrubs.
  const object = await env.CLIPS.get(`clips/${name}`, {
    range: request.headers,
    onlyIf: request.headers,
  });
  // A clip named by a manifest but never uploaded. Deliberately a real 404: Pages
  // answers a path it holds no file for with the site's own HTML at status 200,
  // which is how a deploy with no media reads as green and plays as black panes.
  if (object === null) return new Response(null, { status: 404 });

  const headers = new Headers();
  object.writeHttpMetadata(headers);
  headers.set('etag', object.httpEtag);
  headers.set('accept-ranges', 'bytes');
  headers.set(
    'cache-control',
    MOMENT_IN_NAME.test(name) ? `public, max-age=${YEAR}, immutable` : `public, max-age=${HOUR}`,
  );
  // Set rather than inherited from the object's stored metadata. An upload that
  // forgot --content-type would otherwise serve octet-stream, and the one
  // symptom is a video element that silently plays nothing -- the failure
  // smoke.sh asserts content-type to catch, which this makes unrepresentable
  // instead.
  headers.set('content-type', 'video/mp4');

  // onlyIf matched, so R2 returned metadata without a body and the client already
  // holds these bytes.
  if (object.body === undefined) return new Response(null, { status: 304, headers });

  if (object.range && request.headers.has('range')) {
    // R2 gives back whichever form of the range it resolved: an offset with a
    // length, an offset alone (open-ended), or a suffix counted from the end.
    const { offset, length, suffix } = object.range;
    const start = suffix === undefined ? (offset ?? 0) : object.size - suffix;
    const end = length === undefined ? object.size - 1 : start + length - 1;
    headers.set('content-range', `bytes ${start}-${end}/${object.size}`);
    return new Response(object.body, { status: 206, headers });
  }

  return new Response(object.body, { status: 200, headers });
}
