// Hands the dynamic routes to the Python Worker and leaves everything else to
// Pages: the static site beside this file.
//
// `API` is a Pages service binding, set by hand in the dashboard (terraform
// ignores both projects' deployment_configs). It is the only thing that answers
// /api/ and /admin/, so a project without it fails those requests here,
// loudly, which is what smoke.sh reads -- rather than falling through to Pages,
// which serves the site's HTML with a 200 for any path that has no file.
//
// /clips/ is not forwarded: `clips/[[path]].js` streams it from R2 in JS. A
// clip needs no Python, and a broken Python isolate (below) fails every range
// request a video player makes, which reads as a grey pane on a phone.
const FORWARDED = ['/api/', '/admin/'];

// A Python Worker isolate can come up broken: Pyodide's startup throws
// `NoGilError` before any of the app runs (cloudflare/workerd#6624), and that
// isolate fails everything it is handed until it is evicted. A deploy can carry
// such isolates in some colos and not others, so a single-origin check after
// the deploy passes while players nearby get `error code: 1101`. Another
// attempt usually lands on a healthy isolate, and a request that never reached
// the app is safe to send again -- the one write that matters, a score, is
// idempotent besides (`ON CONFLICT DO NOTHING`).
const ATTEMPTS = 3;
// Cloudflare's own error page for a Worker that threw, which the app never
// writes; the app's 5xx answers are its own and are passed through.
const RUNTIME_ERROR = /^error code: 11\d\d/;

async function forward(api, request) {
  for (let attempt = 1; ; attempt++) {
    const last = attempt === ATTEMPTS;
    let res;
    try {
      res = await api.fetch(last ? request : request.clone());
    } catch (err) {
      if (last) throw err;
      continue;
    }
    if (last || res.status < 500 || !RUNTIME_ERROR.test(await res.clone().text())) return res;
  }
}

export async function onRequest({ request, env, next }) {
  const { pathname } = new URL(request.url);
  if (FORWARDED.some(p => pathname.startsWith(p))) {
    return forward(env.API, request);
  }
  return next();
}
