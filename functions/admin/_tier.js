// Which tier is serving this, as declared by the workflow that deployed it --
// the same web/version.json the About panel reads, fetched through the
// static-asset binding rather than over the network.
//
// Declared rather than inferred from the hostname, for the reason the game's
// page already records: a Pages alias or a redirect pointed at production would
// fool a hostname test, while the deploying workflow knows for certain. A local
// `task dev` stamps one, because the alternative is the admin surface refusing
// itself on the surface it is most useful on.
//
// Shared by the login gate and the spoiler gate rather than written twice: they
// ask the same question of the same file, and two copies is one to forget when
// a tier is added.
export async function tier(env, url) {
  try {
    const res = await env.ASSETS.fetch(new URL('/version.json', url));
    return res.ok ? (await res.json()).tier : null;
  } catch {
    // No ASSETS binding, or a version.json that is not JSON. Both are
    // "unknown", and every caller here treats unknown as the locked-down
    // answer.
    return null;
  }
}
