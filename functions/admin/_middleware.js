// A login in front of everything under /admin/ -- the review page itself and
// both verbs on /admin/day.
//
// Pages runs Functions ahead of static assets, so middleware here gates the page
// as well as the endpoints. That is why it lives here rather than at the top of
// each handler: the next admin route is gated by existing, instead of by
// somebody remembering to gate it.
//
// WHAT ACTUALLY GUARDS WHAT. On the hostnames Cloudflare Access fronts -- the
// project's pages.dev URL and its per-branch aliases -- an unauthenticated
// request never reaches this code, because Access answers it with a login. What
// arrives here carries a JWT that Access signed, and the whole job below is
// proving that signature, since a header is only worth anything if the request
// really came through Access.
//
// On every other hostname there is no Access application and so no JWT, and this
// refuses. That is deliberate rather than a gap: guessr.dana.lol and
// stage.guessr.dana.lol resolve through Route53, which means Cloudflare cannot
// put an Access application in front of them without the zone moving, and the
// alternative to refusing is the world-readable admin surface this exists to
// close. So the review page is reachable at the pages.dev URL and nowhere else.
//
// The spoiler gate in day.js is a separate question and stays: this says who is
// asking, that says which tier may answer at all.
import { tier } from './_tier.js';

const json = (body, status) =>
  new Response(JSON.stringify(body), {
    status,
    headers: { 'content-type': 'application/json', 'cache-control': 'no-store' },
  });

const bytes = (b64) => {
  const raw = atob(b64.replace(/-/g, '+').replace(/_/g, '/'));
  return Uint8Array.from(raw, c => c.charCodeAt(0));
};
const part = (b64) => JSON.parse(new TextDecoder().decode(bytes(b64)));

const RSA = { name: 'RSASSA-PKCS1-v1_5', hash: 'SHA-256' };

// Access's public signing keys, cached for the life of the isolate and refetched
// whenever a token names a key this copy has not seen. Access rotates them, and
// a cache with no way to miss would refuse every request until the isolate
// happened to recycle.
let keys = null;
async function signingKey(teamDomain, kid) {
  if (!keys?.[kid]) {
    const res = await fetch(`https://${teamDomain}/cdn-cgi/access/certs`);
    if (!res.ok) return null;
    keys = Object.fromEntries((await res.json()).keys.map(k => [k.kid, k]));
  }
  return keys[kid] ?? null;
}

// Who Access says this is, or null for anything that does not verify. Exported
// for the tests, which is the only way to exercise a forged token.
export async function identity(token, teamDomain, aud, now = Date.now()) {
  const [head, body, sig] = String(token).split('.');
  if (!head || !body || !sig) return null;

  let header, payload;
  try {
    header = part(head);
    payload = part(body);
  } catch {
    return null;
  }

  // Pinned, not read from the token: `alg` is attacker-controlled, and honouring
  // whatever it says is the oldest way to turn a signature check into a
  // formality -- `none` verifies nothing, and an HMAC keyed on a public key
  // verifies for anybody who can read the public key.
  if (header.alg !== 'RS256' || !header.kid) return null;

  const jwk = await signingKey(teamDomain, header.kid);
  if (!jwk) return null;
  const key = await crypto.subtle.importKey('jwk', jwk, RSA, false, ['verify']);
  const signed = new TextEncoder().encode(`${head}.${body}`);
  if (!(await crypto.subtle.verify(RSA, key, bytes(sig), signed))) return null;

  // Signed by this team, issued for this application, and still valid. All
  // three: anybody can have a Cloudflare team of their own and sign whatever
  // they like with it, and a token minted for a different application in this
  // team is a token for a different application.
  if (payload.iss !== `https://${teamDomain}`) return null;
  if (![].concat(payload.aud ?? []).includes(aud)) return null;
  if (!(now / 1000 < payload.exp)) return null;

  return payload.email ?? 'authenticated';
}

export async function onRequest(context) {
  const { request, env, next } = context;
  const url = new URL(request.url);

  // The one tier no Access application sits in front of, and the one where
  // refusing would be all cost: `task dev` writes that value by hand and no
  // deploy workflow ever writes it. Anything else -- including a version.json
  // that is missing or will not parse -- is gated, which is the same direction
  // of being wrong the spoiler gate picks.
  if ((await tier(env, url)) === 'local') return next();

  // Deployed without the Access application's details, which is what every tier
  // looks like until the terraform is applied and the values are set on the
  // Pages project. Closed rather than open, and said plainly, because the other
  // way to be wrong here is to serve tomorrow's answers to the internet.
  if (!env.ACCESS_TEAM_DOMAIN || !env.ACCESS_AUD) {
    return json({ error: 'no Access application is configured for this deployment, so /admin/ is closed' }, 503);
  }

  const token = request.headers.get('cf-access-jwt-assertion');
  const who = token && (await identity(token, env.ACCESS_TEAM_DOMAIN, env.ACCESS_AUD));
  if (!who) {
    return json({
      error: 'sign in to reach /admin/ — it is only served on the Access-protected pages.dev hostname',
    }, 403);
  }

  return next();
}
