// Hands the dynamic routes to the Python Worker when this project is bound to
// one, and leaves everything else to Pages.
//
// `API` is a Pages service binding, set by hand in the dashboard. Without it --
// production, and `wrangler pages dev` -- every request falls through to the
// Functions and static assets beside this file, so the binding alone decides
// which runtime answers /api/, /admin/ and /clips/.
//
// A forwarded request never reaches functions/admin/_middleware.js, so on a
// bound tier the Worker owns the admin login as well as the handlers.
const FORWARDED = ['/api/', '/admin/', '/clips/'];

export async function onRequest({ request, env, next }) {
  const { pathname } = new URL(request.url);
  if (env.API && FORWARDED.some(p => pathname.startsWith(p))) {
    return env.API.fetch(request);
  }
  return next();
}
