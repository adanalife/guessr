// The palette, before first paint, so a page never flashes the wrong one. Load
// it as a plain blocking <script> in <head>; it is deliberately not a module,
// because a module is deferred and deferred is after the flash.
//
// Same `theme` key and same light/dark values as the blog, though the two are
// separate origins and so keep separate copies of the choice. The game and the
// admin page are the same origin, so choosing a theme on one sets both.

// Everywhere the palette has to be set at once: the attribute the stylesheet
// keys off, the UA's own scrollbar and form-control colours, and the mobile
// browser chrome. The meta tag has to be above this script for that last one --
// and a page without one (the admin page) just skips it.
function setTheme(theme) {
  var d = document.documentElement;
  d.setAttribute('data-theme', theme);
  d.style.setProperty('color-scheme', theme);
  var meta = document.querySelector('meta[name=theme-color]');
  if (meta) meta.setAttribute('content', theme === 'dark' ? '#1a1a1a' : '#fffff8');
}

function toggleTheme() {
  var next = document.documentElement.getAttribute('data-theme') === 'dark' ? 'light' : 'dark';
  setTheme(next);
  try { localStorage.setItem('theme', next); } catch (e) { /* nothing to remember */ }
}

// A Safari private window throws rather than returning null, and an
// unreadable preference is no reason to serve an unthemed page.
var savedTheme = null;
try { savedTheme = localStorage.getItem('theme'); } catch (e) { /* fall back to the OS */ }
setTheme(savedTheme || (matchMedia('(prefers-color-scheme: dark)').matches ? 'dark' : 'light'));
