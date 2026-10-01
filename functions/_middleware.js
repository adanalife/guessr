// Hands the dynamic routes to the Python Worker and leaves everything else to
// Pages: the static site beside this file.
//
// `API` is a Pages service binding, set by hand in the dashboard (terraform
// ignores both projects' deployment_configs). It is the only thing that answers
// /api/, /admin/ and /clips/, so a project without it fails those requests here,
// loudly, which is what smoke.sh reads -- rather than falling through to Pages,
// which serves the site's HTML with a 200 for any path that has no file.
const FORWARDED = ['/api/', '/admin/', '/clips/'];

export async function onRequest({ request, env, next }) {
  const { pathname } = new URL(request.url);
  if (FORWARDED.some(p => pathname.startsWith(p))) {
    return env.API.fetch(request);
  }
  return next();
}
