// Browser errors to Sentry, started before anything else on the page runs.
//
// A classic script rather than a module, loaded blocking straight after the
// vendored SDK: the game itself is one inline module, and a module that fails
// to load or parse throws before any of its own code could report it. Only an
// SDK already running when that happens sees it.
//
// The DSN is a literal because it is public by design. A browser DSN ships to
// every visitor whatever the page does with it; all it permits is sending
// events to this one project.
//
// No tracing: a stack trace is what a bug report here needs. Replay runs in
// buffer mode only -- the SDK keeps the last minute of the page in memory and
// uploads it only when an error is sent, so a bug report comes with what the
// player did to reach it, and a session that never errors costs no quota. The
// replay quota is shared with the rest of the fleet. The SDK's defaults mask
// every piece of text and block every image and video before anything leaves
// the browser.

// The deploy environment, read off the host that served this copy. Production
// and staging report; a *.pages.dev preview or a local `task dev` stays silent,
// since an error there is someone mid-change who can already see it, and every
// one sent would be noise in the triage of the two that players reach.
function sentryEnvironment(hostname) {
  if (hostname === 'guessr.dana.lol') return 'prod-1';
  if (hostname === 'stage.guessr.dana.lol') return 'stage-1';
  return 'development';
}

(() => {
  var environment = sentryEnvironment(location.hostname);
  Sentry.init({
    dsn: 'https://271c3a391b8ab36dbb649e5887a487f7@o325224.ingest.us.sentry.io/4512142090567680',
    environment: environment,
    enabled: environment !== 'development',
    sendDefaultPii: false,
    integrations: [Sentry.replayIntegration()],
    replaysSessionSampleRate: 0,
    replaysOnErrorSampleRate: 1.0,
  });
})();
