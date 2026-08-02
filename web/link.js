// The URL that carries a player id to their other device, and reading one back
// off the far end.
//
// Split out of index.html for the same reason daily.js is: it is a round trip
// where every failure looks identical from the outside. A name that isn't
// escaped ends the fragment early and the id arrives truncated; a parse that
// reads the wrong key links nothing and says nothing. Both present as a QR code
// that "didn't work".

// The id rides in the fragment rather than the query string because a fragment
// is never sent with the request: it stays out of the logs of everything between
// the two devices.
//
// `base` is the origin and path being played on rather than the canonical
// guessr.dana.lol that the share string uses, because each tier has its own
// database -- a staging id opened on production names a player that database has
// never heard of, and the merge would report nothing moved with nothing to say
// why.
//
// The name travels alongside so the receiving device can say which player it is
// about to become. It is a label and the id is what actually links, so a missing
// or unrecognised one costs the prompt its specifics and nothing more.
export function linkUrl(base, id, name) {
  const params = new URLSearchParams({ link: id });
  if (name) params.set('name', name);
  return `${base}#${params}`;
}

export function parseLink(hash) {
  const params = new URLSearchParams(hash.replace(/^#/, ''));
  const id = params.get('link');
  return id ? { id, name: params.get('name') } : null;
}
