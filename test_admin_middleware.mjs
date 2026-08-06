// Cover the login in front of /admin/: which requests reach the handlers behind
// it, and every way a token can be wrong.
//
// The signature check is the whole security boundary. Access itself is what
// stops an unauthenticated browser on the pages.dev hostname, but this code is
// what stops a request that arrives anywhere else carrying a header it made up
// -- so the cases that matter are the forged ones, and they can only be
// exercised from a test that signs its own tokens.
//
// Real RSA over node:crypto's WebCrypto, which is the same API the runtime
// gives the Function, with the JWKS endpoint stubbed.
import assert from 'node:assert/strict';

import { identity, onRequest } from './functions/admin/_middleware.js';

const TEAM = 'adanalife.cloudflareaccess.com';
const AUD = 'aa11bb22cc33dd44ee55ff66';
const RSA = { name: 'RSASSA-PKCS1-v1_5', hash: 'SHA-256' };

const pair = () => crypto.subtle.generateKey(
  { ...RSA, modulusLength: 2048, publicExponent: new Uint8Array([1, 0, 1]) },
  true,
  ['sign', 'verify'],
);

const access = await pair();
const impostor = await pair();

const jwk = { ...(await crypto.subtle.exportKey('jwk', access.publicKey)), kid: 'key-1' };

// The certs endpoint, stubbed. Also the assertion that the module asks the team
// domain it was given rather than one out of the token, which is the difference
// between checking a signature and checking a signature somebody chose for you.
globalThis.fetch = async (url) => {
  assert.equal(url, `https://${TEAM}/cdn-cgi/access/certs`, 'JWKS was fetched from the wrong host');
  return new Response(JSON.stringify({ keys: [jwk] }));
};

const b64 = obj => Buffer.from(JSON.stringify(obj)).toString('base64url');
const hour = 3600;

async function token({
  key = access.privateKey, kid = 'key-1', alg = 'RS256',
  iss = `https://${TEAM}`, aud = AUD, email = 'dana@example.com',
  exp = Math.floor(Date.now() / 1000) + hour,
} = {}) {
  const head = b64({ alg, kid });
  const body = b64({ iss, aud, email, exp });
  const sig = key
    ? Buffer.from(await crypto.subtle.sign(RSA, key, Buffer.from(`${head}.${body}`))).toString('base64url')
    : '';
  return `${head}.${body}.${sig}`;
}

// THE ONE THAT MATTERS: a token Access signed, for this application, unexpired.
assert.equal(await identity(await token(), TEAM, AUD), 'dana@example.com',
  'a valid Access token was refused');

// And every way of being wrong. Each of these is a token somebody could
// actually present: the impostor cases need nothing but a free Cloudflare team
// or a text editor.
const forgeries = {
  'signed by another key': { key: impostor.privateKey },
  'issued for another application': { aud: 'someone-elses-app' },
  'issued by another team': { iss: 'https://attacker.cloudflareaccess.com' },
  'expired an hour ago': { exp: Math.floor(Date.now() / 1000) - hour },
  'signed by a key the team does not publish': { kid: 'key-nobody-has' },
  // alg=none is the oldest JWT forgery there is, and it costs nothing to try.
  'unsigned': { alg: 'none', key: null },
};
for (const [what, claims] of Object.entries(forgeries)) {
  assert.equal(await identity(await token(claims), TEAM, AUD), null, `a token ${what} was accepted`);
}

// Claims edited after signing, which is the case a naive "decode and read the
// email" check waves through.
{
  const [head, , sig] = (await token()).split('.');
  const swapped = `${head}.${b64({ iss: `https://${TEAM}`, aud: AUD, email: 'someone@else', exp: Math.floor(Date.now() / 1000) + hour })}.${sig}`;
  assert.equal(await identity(swapped, TEAM, AUD), null, 'a token whose claims were rewritten was accepted');
}

// Not a JWT at all. Reached by anything that pokes the header by hand.
for (const junk of ['', 'not.a.jwt', 'two.parts', '...', 'null']) {
  assert.equal(await identity(junk, TEAM, AUD), null, `"${junk}" was accepted as a token`);
}

// The static-asset binding, standing in for whichever workflow deployed this
// copy -- `undefined` is a version.json that 404s, the way a directory nobody
// stamped answers.
const assets = tier => ({
  async fetch() {
    if (tier === undefined) return new Response('nope', { status: 404 });
    return new Response(JSON.stringify({ label: 'test', tier }));
  },
});

const PASSED = 'reached the handler';
const gate = async (tier, env = {}, headers = {}) => onRequest({
  request: new Request('https://adanalife-guessr-staging.pages.dev/admin/day?date=2099-06-01', { headers }),
  env: { ASSETS: assets(tier), ...env },
  next: async () => new Response(PASSED),
});
const body = async res => (await res.text());

const CONFIGURED = { ACCESS_TEAM_DOMAIN: TEAM, ACCESS_AUD: AUD };
const signedIn = async () => ({ 'cf-access-jwt-assertion': await token() });

// A deployed tier with no token: refused, whatever the tier is. This is the
// state every hostname Access cannot front is permanently in.
for (const tier of ['staging', 'preview', 'production', undefined]) {
  const res = await gate(tier, CONFIGURED);
  assert.equal(res.status, 403, `${tier} served /admin/ with no token`);
}

// Signed in: through to the handler. Production too -- the login says who is
// asking and nothing about which tier may answer, which is day.js's own gate
// and is tested there.
for (const tier of ['staging', 'preview', 'production']) {
  const res = await gate(tier, CONFIGURED, await signedIn());
  assert.equal(await body(res), PASSED, `a signed-in request was refused on ${tier}`);
}

// Deployed before the Access application exists, or with half of it set. Closed,
// because the other way to be wrong is serving tomorrow's answers to anybody.
for (const env of [{}, { ACCESS_TEAM_DOMAIN: TEAM }, { ACCESS_AUD: AUD }]) {
  const res = await gate('staging', env, await signedIn());
  assert.equal(res.status, 503, 'a deployment with no Access configuration served /admin/');
}

// Local is the one tier no Access application fronts, so it is the one exemption
// -- `task dev` writes that value by hand and no deploy workflow writes it.
{
  const res = await gate('local');
  assert.equal(await body(res), PASSED, 'the local dev server locked itself out of /admin/');
}

console.log('ok: a token Access signed for this app gets in, and every forgery does not');
console.log('ok: no token is a refusal on every deployed tier, configured or not');
console.log('ok: local dev is the one tier that needs no login');
