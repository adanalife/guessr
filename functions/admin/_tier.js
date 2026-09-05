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

// The tiers this surface answers on at all. Production is one of them: its
// schedule is what a wrong coordinate reaches players through, and its players
// are the ones worth recognising, so a surface built for those has to work there
// or it works everywhere except where it counts.
//
// Still an allowlist rather than nothing, because "which tier is this" has a way
// of coming back unanswerable -- no version.json, a version.json that will not
// parse, a tier nobody has taught this about -- and a deployment this code
// cannot name is one whose Access application it cannot vouch for either.
// Refusing costs a line here when a tier is added; answering costs whatever the
// route behind it serves.
const KNOWN_TIERS = new Set(['production', 'staging', 'preview', 'local']);

// Here rather than in either route, and shared by both for the reason tier() is:
// a second copy of the allowlist is a second thing to remember when a tier is
// added, and the one that gets forgotten is whichever nobody is looking at.
// Each route keeps its own refusal message, since what is unavailable differs.
export const unknownTier = async (env, url) => !KNOWN_TIERS.has(await tier(env, url));
