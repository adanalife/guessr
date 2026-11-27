// GET /reveals/<row>_<col>.jpg -- the still behind "here's where you guessed",
// out of the same private bucket as the clips (see functions/clips/[[path]].js
// for why the media goes through a Function rather than a public bucket).
//
// Stricter about the name than the clips route is, because /api/score hands
// these out for any pin at all: the pattern is the whole of what a reveal can be
// called, so nothing else in the bucket is reachable through this path.
const NAME = /^-?\d+_-?\d+\.jpg$/;
// A cell's still only changes when a regeneration picks a different frame for it,
// which is rare and harmless -- the same stretch of road -- but not never, so a
// day rather than the clips' immutable year.
const DAY = 86400;

export async function onRequestGet({ params, env }) {
  if (!NAME.test(params.name)) return new Response(null, { status: 404 });
  const object = await env.CLIPS.get(`reveals/${params.name}`);
  // Deliberately a real 404, for the same reason as the clips route: Pages would
  // otherwise answer with the site's HTML at 200.
  if (object === null) return new Response(null, { status: 404 });
  return new Response(object.body, {
    headers: {
      'content-type': 'image/jpeg',
      'cache-control': `public, max-age=${DAY}`,
      etag: object.httpEtag,
    },
  });
}
