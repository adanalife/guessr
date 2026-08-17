# Guessr

GeoGuessr, but every round is a few seconds of the A Dana Life dashcam corpus —
a year of driving the United States in 2018.

Five rounds a day, the same five for everyone, with a spoiler-free share string
at the end. Practice rounds are unlimited.

The game is static files plus a few endpoints. `make_rounds.py` does all the work
up front (query the corpus metadata, cut the clips, write the rows describing
them); `web/` is then a plain directory of HTML and JS. The map is Leaflet over
OpenStreetMap tiles.

**A round set is data, not a deploy artifact.** The pool, the day-by-day schedule
and the answers are rows in D1; the clips are objects in R2, streamed back by a
Pages Function. So changing what the game plays is three pushes and no deploy —
and cutting a release went back to being purely about code.

A round plays on a loop and can be paused — the button in the frame's corner, or
the space bar. Motion is what places a scene; a still is what lets you read the
sign in it.

The endpoints are Cloudflare Pages Functions, and they exist because the answers
can't ship to the browser. `GET /api/day` hands out a date's five rounds by name
and nothing else; `POST /api/score` is the only thing that ever reads a
coordinate. They are two tables in the same database, so the endpoint that serves
a game physically cannot leak the answer to it — a player learns where a clip was
taken only by committing a guess and getting the score back.

## Play locally

```sh
task rounds   # needs the corpus mounted + kubectl access to the tripbot DB
task check    # validates the round set
task clips:push  # uploads the media to R2, which is where the game reads it from
task rounds:rebuild IMAGE=clips/<slug>-<ms>.mp4  # restore one lost or corrupt clip
task test     # scheduling, scoring, the endpoints, the swap; needs neither
task test:integration  # the whole game against a throwaway local D1
task dev      # http://localhost:8000, with scoring
task serve    # http://localhost:8000, static only — no rounds, no scoring
```

`task dev` runs `wrangler pages dev` against a local D1 — migrations applied,
then `rounds.sql` and `answers.sql` seeded — so a game loads and guessing works
end to end, including the record a daily play leaves behind.

`task test:integration` is the same stack without a corpus: it fabricates a round
set through the *real* SQL generators, applies the migrations to a throwaway
local D1, starts `wrangler pages dev`, and asserts the endpoints answer. It runs
in CI, and it is the tier that catches what the other two cannot — `task test`
runs handlers against a stub of the D1 binding, so it proves logic and says
nothing about routing, bindings, or how a real database answers, while `smoke.sh`
needs something already deployed.

`task serve` is a plain `http.server`, and it no longer serves a playable game:
the rounds come from `/api/day` and the clips from a Function, neither of which a
static server has. It is still the quickest way to work on anything that is not
the game itself — the About panel, the changelog, layout above the fold.
Both bind all interfaces, so a phone on the tailnet can reach them at
`http://<this-machine>:8000`.

Round generation is the only step with real dependencies: the corpus, and the
corpus metadata in the tripbot Postgres.

It reaches that database two ways, and `DATABASE_HOST` is the switch. Unset — the
laptop — there is no route to it at all, since it sits in the cluster behind no
ingress, so `make_rounds.py` exec's a `psql` that is already inside the pod
(`--namespace` names where). Set, the script connects straight to the Service and
`--namespace` is ignored, which is what lets this run *as* a job in the cluster
rather than from a laptop with `kubectl`. That route needs a `psql` on `PATH` and
reads the same project-wide `DATABASE_USER` / `DATABASE_PASS` / `DATABASE_DB` /
`DATABASE_PORT` vars as tripbot and video-pipeline. `GUESSR_CORPUS` moves the
corpus path off the laptop's SMB mount for the same reason.

`publish.sh` (`task rounds:publish`) is the whole publish sequence in one place —
generate, validate, then the three legs a round set arrives as:

1. **the media**, one R2 object per clip, keyed by the name the round carries
2. **the answers**, rows in the `answers` table
3. **the pool and the schedule**, rows in `rounds` and `round_days`

**The schedule last**, always, because it is the only one of the three that makes
a date playable. Get the order wrong and a player reaches a round whose clip is a
black pane (no media) or whose every guess comes back `unknown round` (no
answers). Push it last and the worst case is a date that is not scheduled yet,
which nobody can see.

**Two modes, one target each.** Bare, this builds a full fresh set for staging,
whose schedule is disposable. With `--top-up` it writes production: read how far
ahead the game is scheduled, generate only what is missing, never place a date
inside the next three days, and exit having generated nothing at all on the weeks
none of that is short.

**Those three days are the safety property.** A job that can write the production
database is a job that can ruin the game unattended — unless what it writes is not
playable yet. The lead is the review window: every round it schedules sits on the
admin page, rejectable, before any player can meet it, so review is possible the
whole time and required never. The guards that do not depend on anyone looking
run either way — `check.py` before anything leaves the machine, `verify_days.sh`
over what actually landed, and a depth check that fails the run if production
comes out of it scheduled less than a week ahead.

No git, no deploy, no pull request. This used to open a PR to commit
`web/rounds.json`, because the round set was a file and a deploy was the only way
it could reach anyone — which meant a scheduled job would have needed a token with
write access to a public repo's default branch. Rows in D1 need none of that.

The trade, stated plainly rather than discovered later: `pr-gates` used to run
`check.py` over the committed manifest, and there is no longer a PR for it to run
on. `check.py` runs inside `publish.sh` before anything is pushed instead —
earlier than the gate did, but on the generating machine's word alone — and
`smoke.sh` measures a *deployed* clip's aspect ratio against every tier, which is
the assertion that catches an uncropped HUD.

A weekly CronJob runs the top-up: `guessr-rounds`, Mondays, cloning this repo and
calling `./publish.sh --top-up`. It is defined in the `video-pipeline` repo's
cdk8s rather than here, because that image already carries everything a
generation needs beyond this script — `ffmpeg`, the corpus mounted read-only, a
route to the Postgres, and a CPU limit low enough to keep batch work off the live
stream. Its only credential is a Cloudflare token: R2 write on the clips bucket
and D1 write. No GitHub credential, which is the part that makes running it
unattended reasonable at all.

## Deploying

Three tiers, two Cloudflare Pages projects:

| | URL | Deploys when | Workflow |
| --- | --- | --- | --- |
| preview | a `*.pages.dev` branch alias, posted as a PR comment | every pull request | `preview.yml` |
| staging | [stage.guessr.dana.lol](https://stage.guessr.dana.lol) | every merge to `main` | `staging.yml` |
| production | [guessr.dana.lol](https://guessr.dana.lol) | a `vX.Y.Z` tag ships | `release.yml` |

So every change is visible before it merges, `main` is always live *somewhere*
to look at, and the game people play only moves when a release goes out.
Cutting one means merging the standing `chore(main): release X.Y.Z` PR —
release-please tags it and dispatches `release.yml` at the tag. Nothing else
promotes to production.

Previews share the staging Pages project, on a per-branch alias that leaves its
production alias (`stage.guessr.dana.lol`) alone. A PR from a fork or from
Dependabot gets no preview: GitHub withholds the Cloudflare token from those
runs, so the job skips rather than failing.

All three deploys stamp `web/version.json` and copy `CHANGELOG.md` in beside
it, so the About panel can name the running build and show what changed — the
tag on production, `main@<sha>` on staging, `PR #<n>@<sha>` on a preview.
Neither file is committed, so a locally served copy just shows no version.

`version.json` also carries the `tier` that deployed it, which is what puts a
**Reset saved state** button in the About panel everywhere except production.
The intro dialog, the About dot and the daily result are each once-per-browser,
so testing any of them a second time otherwise means clearing site data by hand.
Reset drops every `guessr-`prefixed key and reloads. A locally served copy has
no `version.json` at all and gets the button too.

The same tier gates a **Place random** button beside Guess, which drops a pin at
a uniform point in the playable box and commits it — a five-round game in five
clicks when what is being tested is anything other than aiming. It drives the
map's click handler and the Guess button rather than its own copy of either, so
the play it records is a real one: on staging the leaderboard carries those
alongside genuine scores, under the same player id as the browser's real plays,
since the id is also the device-link credential and a second one would fork the
identity mid-game. This gate is stricter than reset's — no readable
`version.json` means no button, because a misfire spends a player's one play of
the day. `task dev` stamps a `local` tier, so local work still gets it.

The Pages projects and the DNS records are terraform, in the `infra` repo under
`terraform/prod-1/cloudflare-pages-guessr.tf` and `terraform/core/route53.tf`.

`web/` holds `index.html`, its scripts (`daily.js`, `zoom.js`, `alias.js`,
`link.js`, `share.js`, `theme.js`), `base.css`, `manifest.json`, the icon and
share-card assets (`favicon.svg`, `apple-touch-icon.png`, `icon-512.png`,
`og.jpg`), the admin page under `admin/`, and the ET Book faces under
`et-book/`.

**No part of a round set is committed, and none of it is deployed.** The clips
could never be — a set is ~150 MB of mp4 and this repo is public, so committing
one would add that to git history on every regeneration, permanently. The rows
describing them could be, and deliberately are not: a round set that lives in git
is a round set that needs a pull request and a deploy to change, which is the
thing moving it into D1 undid.

So `web/clips/` is gitignored and is a build directory, not a deployed one:
`clips.sh push` sends its contents to R2 and `functions/clips/[[path]].js`
streams each object back at request time, with `Range` support so the video
element can seek. A deploy is a few hundred KB of HTML and JS, and a regeneration
changes nothing about it at all.

The object key is exactly the `image` a round carries, so there is no mapping to
keep in step — and because that name includes the moment the clip was cut from,
a regeneration cannot put different footage behind a name a browser already
cached, which is what makes the long `immutable` header safe. Nothing in the
bucket is ever deleted: an object is load-bearing for as long as any round names
it, and at ~0.5 MB a clip against 10 GB of free storage there is no pressure to
work out which.

The page borrows its look from the blog at
[dana.lol](https://dana.lol): the same ET Book faces, and the same light/dark
palette behind a `data-theme` attribute that an inline script sets before first
paint and a footer toggle flips. Only three of the four ET Book faces are
vendored (roman, italic, bold) and only as `woff` — the old-style-figures face
has nothing to set here, and the `eot`/`svg`/`ttf` copies target browsers this
game does not otherwise support. The faces are
[ET Book](https://github.com/edwardtufte/et-book), MIT-licensed; the notice
travels with them in `web/et-book/LICENSE`.

Tufte CSS's own stylesheet is deliberately not used: nearly all of it is
article layout — sidenotes, 55%-wide sections, figures — which has nothing to
say about a full-viewport game. A handful of things stay outside the palette on
purpose, each with a note where it is set: the zoom controls copy Leaflet's,
and the badges, the minimap frame and the legend swatches sit on photographs or
map tiles rather than on the page.

`functions/` holds the endpoints. It is not served: Pages routes
`functions/api/score.js` to `/api/score`, `functions/api/day.js` to `/api/day`,
`functions/admin/day.js` to `/admin/day` and `functions/clips/[[path]].js` to
everything under `/clips/`. `_scoring.mjs` is skipped by the router (leading
underscore) so the handlers can import it.

`/api/day` is what a date's game *is*: five rounds by name, in the order they
play. `/api/score` checks a posted round against the same rows before it will
record anything. That property — the rounds scored against are provably the
rounds the page handed out — used to hold because both sides imported the same
draw and the same pool from the same commit, so a half-finished deploy could
break it. There is one row set now and both read it, so a deploy cannot come into
it at all.

`daily.js` is still shared, and still an ES module for that reason (which is also
why the page's inline script is `type="module"`) — but only for the play window
now. When a date is open is a rule about clocks rather than data, and the page
and the scorer still have to agree on it or one accepts what the other refuses.

### The rows a round set is

`task rounds` writes four files *outside* `web/`, and none is committed.
`rounds.json` + `rounds.sql` are the pool and the schedule; `answers.json` +
`answers.sql` are every round's lat/lng/state/date. In each pair the JSON is what
`check.py` asserts against and the SQL is what wrangler eats.

They stay out of `web/` because that is the entire deployed surface, so anything
in there is fetchable — and out of git because this is a public repo, where a
committed answer key is the game given away.

They reach a tier through D1:

```sh
task answers:stage:push   # the coordinates
task rounds:stage:push    # the pool and the schedule
```

**A round set does nothing until both run**, in that order. Without the schedule
no date has a game at all and `/api/day` 404s; with a schedule but no answers the
game looks perfect and returns "unknown round" on every guess. `task rounds`
prints both on the way out, alongside `task clips:push`, without which the rounds
have no footage to show in the first place.

Losing a single clip is a black pane in somebody's game rather than a broken
deploy, because the endpoint reads the bucket per request. `task rounds:rebuild
IMAGE=clips/<slug>-<ms>.mp4` puts it back: it reads the round's provenance out of
D1, re-cuts from the corpus with the same ffmpeg invocation that made it, and
replaces the object under the same key. The moment being in the filename is what
makes that land the same footage at the same URL, which is also what makes the
year-long `immutable` cache header on `functions/clips/[[path]].js` safe — so the
command refuses rather than guesses whenever the key and the round disagree.

There is deliberately no `rounds:prod:push`. Production is reached only through
`task rounds:topup`, whose contract — only what is missing, never inside the
review window, never a clip the tier already holds — is exactly what a bare push
of a fresh `rounds.sql` would not honour.

The databases are terraform, in `infra` alongside the Pages projects, and each
tier has its own so a regeneration on one doesn't strand the other.

### The tables the game owns

Every table definition lives in numbered migrations under `migrations/` —
`rounds`, `round_days`, `answers`, `plays`, one row per player per round per
date, which is the whole storage behind the leaderboard, and `players`, which
holds only the ids somebody has put a name to.

```sh
task schema:stage:status   # what this tier has not applied yet
task schema:stage:apply
task schema:prod:apply
```

**A fresh database needs this before any seed will land.** The definitions are
kept out of the generated files because the two change on completely different
clocks: `rounds.sql` and `answers.sql` are rewritten with every round set, while
the shape moves rarely. Folding them together would put the definition of a table
of player scores inside a gitignored file that only exists on whichever laptop
last built a round set.

**Why a ledger and not one idempotent file.** `wrangler d1 migrations apply`
records what it has run in each database's own `d1_migrations` table, so
`:status` answers *"how far behind is this tier"* — a question a hand-run push
can only answer by trying something and seeing whether it 500s. It also unblocks
`ALTER TABLE`, which SQLite gives no `IF NOT EXISTS`, so a re-runnable single
file can only ever add tables and never change one.

Writing one: `npx wrangler d1 migrations create <db> <description> --config
wrangler.d1.jsonc`, then fill in the file. The conventions, which are tripbot's
minus the parts D1 will not take:

- **`NNNN_snake_case_description.sql`**, four digits, applied in filename order.
  (tripbot uses three; wrangler's `create` generates four and renaming them by
  hand to match would drift the moment somebody uses the tool.)
- **A header comment saying *why*, not *what*.** Same as tripbot's — the schema
  is where the reasoning behind a shape has somewhere permanent to live.
- **No `.down.sql`, and this one is a trap rather than a preference.** Wrangler
  globs `migrations/*.sql` and applies everything unapplied in order, so a down
  file is treated as *the next migration* and would undo its own up on the same
  run. D1 migrations are forward-only; to reverse something, write a new one.
- **Bare DDL.** The ledger guarantees single application, so a guard would only
  hide a numbering mistake. `0001` is the sole exception and says why in its own
  header: it has to be adoptable by the databases that predate the ledger.

`wrangler.d1.jsonc` is where the three databases are declared, and its header
explains the one asymmetry worth knowing: `d1 execute` resolves a bare database
name against the API, `d1 migrations` refuses to run without a config *and* a
`database_id`.

A row is written the first time a player answers a round on a given date, and
never updated: guessing that round again returns the score already on record.
Without that, a client could score the same round repeatedly and keep its best
number, and a board built on top would rank whoever re-guessed most rather than
who guessed best. Practice rounds send no date, so they are scored and never
stored — which is why practice can be replayed freely and the daily cannot.

Identity is an opaque id minted into `localStorage` on first play; the handle a
player types rides alongside as a display label. It is deliberately not the
handle (two players called "Jason" would collapse into one, and the second one's
play would read as a replay of the first's) and deliberately not the IP address
(NAT makes a household one player, CGNAT makes one phone several, and an address
stored beside a typed name is personal data this doesn't need).

### Linking a second device

An id per browser means a player who plays on a phone and a desktop is two
players on the board. `POST /api/link` with `{from, to}` folds one into the
other: every play under `from` is rewritten to `to`, and a round both browsers
answered on the same date keeps the score already on record under `to` — first
write wins, the same rule the primary key exists to enforce — while the other
copy is dropped rather than left behind.

There is no account to log into, and adding one would be the whole apparatus (an
email, a session, a way back in when it's lost) around a problem that is one row
rewrite. The id already *is* the credential: minted in the browser, never
returned by any endpoint, `/api/leaderboard` deliberately serving names and
points and no ids. So holding both ids is proof of holding both browsers.

The About panel's **Link a device** draws that URL as a QR code, and the browser
that scans it merges and adopts. A code rather than a copyable link because
copying was the hard half: a URL on a desktop still has to reach a phone, and
every route there is a detour out of the game. It stays an `<a>` around the
image, so a screen reader still announces a link and a phone with the panel open
can follow it directly.

The id rides in the fragment rather than the query string, so it is never sent
with the request and stays out of the logs it passes through on the way; and the
URL is built on the current origin rather than `guessr.dana.lol`, because each
tier has its own database and a staging id opened on production names a player
nothing has heard of. `web/link.js` owns both halves — building the URL and
reading one back — split out for the same reason `daily.js` is: a name that
isn't escaped and a parse that reads the wrong key both present as a code that
did nothing.

Adoption runs on load *and* on `hashchange`, because opening the link isn't
always a page load — a browser already showing the game reuses the tab, and the
URL differs only in its fragment. The receiving browser asks first, naming the
player it is about to become: a URL that silently rewrote who you are would be a
URL anyone could send you.

Encoding is `qrcode-generator` from unpkg, pinned alongside Leaflet. QR is
Reed-Solomon over GF(256), block interleaving and mask scoring — a spec
implementation rather than something to write, and one whose bugs are a code that
scans on the phone it was tested with and not the next one. It adds a request
rather than a trust boundary: the page already gives that origin the run of
itself.

The consequence worth being plain about: anyone who learns a player's id can take
that history. That's the exposure the id already carried — knowing it lets you
post plays as that player — and the mitigation is the same one, which is that it
has no path out of the browser holding it.

### The boards

`GET /api/leaderboard?board=daily|monthly` returns `{board, period, rows}`, rows
being `[name, points]` pairs, best first. Ten of them, since the overlay renders
five and the extra leaves room to filter without a second request.

The **daily** board is the most recently *closed* date, never one still filling.
Three dates are open at once, so "today" isn't a single answer, and the
alternative — the streamer's own date, labelled in-progress — puts a board on
screen that can reorder while it's up. The **monthly** board is a running total
over the current month and needs no closing rule, because a sum has nothing to
settle.

It's a read the stream pulls, not a write the game pushes. The cluster tripbot
runs in has no inbound path, deliberately, and a leaderboard isn't a reason to
open one — so the game keeps scores where it already writes them and the bot
fetches on its own schedule. Both boards take a slot in the onscreen rotation
([tripbot#1306](https://github.com/adanalife/tripbot/pull/1306)), and `!guessr`
puts one up on demand
([tripbot#1309](https://github.com/adanalife/tripbot/pull/1309)). The board being
unreachable costs a rotation slot and nothing else.

### Names on the stream

Rows carry the player's alias, and it is safe to render as stored because of
where it comes from: a curated wordlist, so the review happens when the name is
*made* rather than after it is typed. There is no moderation queue because there
is nothing a stranger chose. A play with no name at all — one recorded before
aliases existed, or from a browser that can't keep `localStorage` — renders as
`anonymous` and still places.

If typed names ever land, an allowlist lands with them and joins into the board
query; until then it would be a table with nothing to hold.

One name does not come from the wordlist. `players` maps a player id to an alias
an operator set by hand, and it wins over the one the player drew — for the
friends and regulars worth recognising by name:

```sh
task player:prod ID=<player_id> NAME='Phil' NOTE='met at the meetup'
```

The ids come out of `task stats:prod`, which prints one beside every best-day
score. **`NAME` is published** — it replaces that player's own name everywhere
one renders, the stream overlay included — while `NOTE` is read by nothing and
served by nothing. So a note alone recognises somebody without announcing what
you recognised them by, which is usually the one you want. Either argument left
empty clears it.

One thing this does *not* buy outright: the round sets published before scoring
moved server-side carried their coordinates in `rounds.json`, and that file is in
this repo's git history. The current set is a later regeneration and most of it
is clear of them, but 34 of its 300 rounds are cut from a clip that also appeared
in one of those sets — and those sets' coordinates were clip-level, so for those
the answer is a couple of kilometres and a `git log` away. The endpoint is the
mechanism; a set with no overlap at all is what would make it the guarantee.

A regeneration replaces every clip under `web/clips/` and rewrites the four files
beside the repo — so **a generation that fails leaves the current one alone.**
`task rounds` builds into `web/.staging`, runs `check.py` against *that*, and
moves it into place only if it passes. A run with the corpus unmounted or the
database unreachable leaves the working tree exactly as it was rather than
deleting the clips it was about to replace, and the rejected set is left in
`web/.staging` to look at.

The live game is untouched by any of it either way: what players see is rows in
D1 and objects in R2, and a generation writes neither until it is published.

`favicon.svg` is the map pin, drawn as the adanalife mark — ring, centre dot,
bead on the upper-right shoulder — with the ring pulled down to a point, so it
reads as both. It's the source every other icon derives from.

`apple-touch-icon.png` is that mark for the iOS home screen. Safari wants a PNG
there and ignores its alpha, so the background is baked in rather than left
transparent:

```sh
rsvg-convert -w 124 -h 124 web/favicon.svg -o /tmp/mark.png
magick -size 180x180 xc:'#1a1a1a' /tmp/mark.png -gravity center -composite \
  -depth 8 -strip PNG32:web/apple-touch-icon.png
```

`manifest.json` is what makes an installed copy open standalone — its own
window, no URL bar — instead of in browser chrome. `icon-512.png` is the icon
it points at, same mark on the same background:

```sh
rsvg-convert -w 352 -h 352 web/favicon.svg -o /tmp/mark.png
magick -size 512x512 xc:'#1a1a1a' /tmp/mark.png -gravity center -composite \
  -depth 8 -strip PNG32:web/icon-512.png
```

It's declared `maskable`, so Android crops it to the platform's icon shape
rather than shrinking it into a white tile. That crop can take the outer 10%
on each side, which is why the mark occupies ~69% of the canvas and not more.
There is no service worker and no offline mode — installing gets the window
and the icon, nothing else.

`og.jpg` is the link preview, and the link preview is the whole distribution
mechanism: this game spreads by people pasting a URL. It's a hand-picked frame
with the title and the mark set over it, made once and committed:

It is cut straight from the corpus rather than from a round clip, so it does not
go stale when the round set is regenerated — `2018_1107_182338_002_opt` at
87.9s, a Victorian intersection in San Francisco:

```sh
rsvg-convert -w 110 -h 110 web/favicon.svg -o /tmp/mark.png
magick /tmp/mark.png -channel RGB -fill white -colorize 100 +channel /tmp/mark-white.png

ffmpeg -ss 87.9 -i /Volumes/ADanaLife/dashcam/_opt/clips/2018_1107_182338_002_opt.MP4 \
  -frames:v 1 -vf "crop=iw:ih-70:0:0,scale=1280:-2" -q:v 2 /tmp/card.jpg

magick /tmp/card.jpg \
  -gravity North -crop 1280x672+0+0 +repage -resize 1200x630! \
  \( -size 1200x300 -define gradient:vector='0,0 0,300' \
     gradient:'rgba(0,0,0,0.62)-rgba(0,0,0,0)' \) -gravity North -composite \
  -font Helvetica-Bold -fill white -gravity NorthWest \
  -pointsize 96 -annotate +60+52 'Guessr' \
  -font Helvetica -pointsize 36 -fill '#dfe6ea' \
  -annotate +64+168 'Like GeoGuessr, but every round is a dashcam clip' \
  -annotate +64+214 'from a year-long roadtrip' \
  /tmp/mark-white.png -gravity NorthEast -geometry +60+46 -composite \
  -quality 88 -strip web/og.jpg
```

The mark is white here rather than its green: over a sunlit frame the green
sinks into whatever foliage is behind it, and white matches the title.

Swapping the frame means re-running that and updating `og:image:alt`. Keep it
1200x630 — that's the aspect every scraper crops to.

The recipe names a corpus clip and a timestamp rather than a file from the
current round set, which is what makes it reproducible. A round set is
regenerable and its frames turn over, so a recipe keyed to one rebuilds a
*different* card the moment that frame leaves the set — leaving compositing onto
the existing image as the only way to change anything. The corpus clip behind
this frame is not going anywhere.

(The source frame was recovered by scanning every San Francisco clip in the
corpus for the one whose untexted lower band matched the committed card: 0.039
RMSE against 0.20+ for every other candidate. The rebuilt card is that scene a
fraction of a second off — near enough that the difference is a pedestrian
mid-crossing.)

## Development

```sh
pre-commit install   # wires up both the file hooks and the commit-msg check
```

Commits and PR titles follow [Conventional Commits](https://www.conventionalcommits.org).
PRs squash-merge, so the PR title becomes the subject in history and is what
release-please reads to compute the next version.

### Changelog

`CHANGELOG.md` is assembled by [towncrier](https://towncrier.readthedocs.io)
from one fragment per PR, so every PR adds one:

```sh
task changelog:add TYPE=new     # writes changelog.d/+new.new.md — open it and write the line
task changelog:preview          # what the next release will say
```

Types are `new`, `changed`, `fixed`, `behind` (behind the scenes) and `summary`
(a lead paragraph for the release, when one is warranted). You don't need the PR
number: `changelog-number.yml` renames the `+` placeholder to `<PR#>.<type>.md`
on push, which is what puts a PR link on each entry. A PR that genuinely
warrants no entry — a dependabot bump, a round-set regeneration, a revert —
carries the `skip-changelog` label instead, and `gates` fails without one.

**Write the entry for a player.** That file is what the version number in the
About panel links to, so it's read by someone who just finished a round and
tapped it — not by anyone who will ever open this repo. Say what changed for
them, in their words, in the present tense:

> The map remembers how far you zoomed in.

not

> persist zoom level to localStorage

No file names, no endpoints, no repo jargon; if a line only parses next to the
diff, it belongs in the PR description. Plumbing still gets a line, under
**Behind the scenes** — plainly, not in the jargon that section might seem to
invite.

Releases assemble it automatically: release-please's standing PR carries the
version bump, and a step on that branch collates the fragments into
`CHANGELOG.md` so the notes and the bump land together. Entries from before
towncrier are still in the old release-please style below the
`<!-- towncrier release notes start -->` marker.

## The daily round

Everyone playing on the same calendar day draws the same five rounds. There is
no server deciding that: the draw is seeded from the day number, so every client
computes the same set independently. The day turns over at the player's own
local midnight.

The share string is the Wordle shape — a square per round, banded by score, with
no locations in it:

```text
Guessr #1
🟩🟨🟩⬜🟧
18,204 / 25,000
```

A guess within a kilometre of the truth takes a 🏆 instead of its square. The bar
is set from `plays` rather than picked: 2.7% of recorded guesses land inside 1 km,
so it turns up in roughly one game in eight.

Finishing writes the day to `localStorage`, so today's round can't be replayed
for a better result. Practice mode draws at random and is unlimited.

A date's five arrive from `/api/day` already ordered easy to hard by `median_km`
(see [How rounds are chosen](#how-rounds-are-chosen)) — the ramp is applied when
the date is scheduled, so the page does not sort and `median_km` is never sent at
all. The ramp is felt, not shown; nothing in the header rates the round you are
looking at.

`test_schedule.py` covers the scheduling, because it fails invisibly. The
properties it pins: a date's five come out in ramp order, no round is ever
scheduled twice, the schedule does not depend on the order the pool was written
in, and — the one worth a test rather than a glance — every day spans the
difficulty range instead of sitting in one part of it. Dealing rounds out in
blocks of five would satisfy everything else and produce a month that gets
steadily harder rather than a game that does.

`test_daily.mjs` covers what is left in `daily.js`: the date arithmetic and the
play window, where a DST boundary that skips or repeats a day number files a
score against the wrong board.

### When a day is open

A date is playable from midnight in the earliest timezone on Earth to midnight in
the latest — 10:00 UTC the day before until 12:00 UTC the day after, 50 hours, so
everyone gets their own full day. Up to three dates are therefore open at once,
which is why a board on the stream has to name the date it is showing rather than
assume there is a single "today".

Both endpoints enforce the window, for different reasons. `/api/score` refuses a
play outside it — the close is what lets a board be final. `/api/day` refuses to
*name* the rounds of a date that has not opened, which is the whole protection on
a schedule now the browser cannot derive it: while the draw was a seeded shuffle
over a committed pool, anyone could work out next month's five and there was
nothing to withhold. A refusal comes back as a 403 with a distinct message, and
the page treats a 4xx as final rather than inviting a retry that cannot work.

### Previewing a day

`/admin/` is the deliberate exception to that refusal: pick a date, watch its
five clips in order, and check each answer on a street-zoom map. It reads
`/admin/day`, which serves any date at all — unopened ones included — with the
coordinates joined on, so a dud clip or a pin in the wrong place is caught before
a real day is made of it. Past dates read the same way, which is how a finished
day gets looked at again.

**It is behind a login.** `functions/admin/_middleware.js` gates everything under
`/admin/` — Pages runs Functions ahead of static assets, so that covers the
review page itself and not only the endpoints beneath it. The login is Cloudflare
Access, which fronts the project's `pages.dev` hostname and its per-branch
aliases: on those, an unauthenticated request never reaches the code, and what
does arrive carries a JWT that Access signed, which the middleware verifies
(right team, right application, unexpired) before letting anything through.

The custom domains are the reason the check is in the Function and not only at
the edge. `guessr.dana.lol` and `stage.guessr.dana.lol` resolve through Route53,
so Cloudflare cannot put an Access application in front of them without the zone
moving — no Access means no JWT, and no JWT is a refusal. **So the review page is
reachable at the `pages.dev` URL and nowhere else.** Two values off the Access
application, `ACCESS_TEAM_DOMAIN` and `ACCESS_AUD`, are set on the Pages project;
a deployment missing them answers `503` and serves nothing, which is the state
every tier is in until the Access application exists. `task dev` is the one
exemption — a `local` tier skips the login, since nothing fronts localhost.

**Production is one of the tiers it answers on**, and the tier check that says
so is a second question from the login: the login says who is asking, the tier
says which deployment may answer at all. The Function reads the same
`web/version.json` the About panel does, through the static-asset binding, and
answers `403` unless the deployment declares itself `production`, `staging`,
`preview` or `local`. Every other answer — no `version.json`, one that will not
parse, a tier nobody has taught it about — refuses, since a deployment this code
cannot name is one whose Access application it cannot vouch for, and the cost of
a false refusal is a line in an allowlist while the cost of a false answer is
tomorrow's five and where they are.

Production is where a wrong coordinate actually reaches players, so it gets its
own Access application over `adanalife-guessr.pages.dev/admin` — the staging one
covers only the staging project's hostnames. Both live in the infra repo,
alongside the Pages projects they front.

Rejecting a round is built (a button per round, replaced from the queue's tail);
reordering a day is not. Looking is most of the value and it is what makes the
rest worth having, so it went first.

**Rounds no longer repeat.** A date's five are dealt from the pool once and
recorded, and `round_days_once` makes scheduling the same round twice impossible
rather than merely unlikely. Under the reshuffling draw this replaced, a player
who played all of the next 90 days met 233 of 300 rounds and saw a repeat about
every other round.

What that trades for is a finite corpus. Five a day is 1,825 rounds a year
against ~4,400 clips, of which perhaps half clear the quality bar and the
coordinate-confidence gate — so somewhere around a year to eighteen months, the
generator will fail to fill its horizon. `round_days_once` is what will announce
it, and relaxing it (the same clip at a different moment) is a one-line change.

## How rounds are chosen

Sampling clips uniformly produces a lot of anonymous interstate, where even a
perfect guess is luck. So candidates are scored first, using the SigLIP2
`frame_embeddings` that already back the `!find` command.

The question the score asks is **"do visually similar frames come from nearby
places?"** For each candidate, take its 25 nearest neighbours in embedding space
and measure the median great-circle distance from the candidate's true location
to theirs. A tight cluster means the image carries real location signal; a
median in the thousands of kilometres means the look is generic.

It discriminates sharply. In one 150-clip pool the best-scoring frames were a
street corner in San Francisco's Mission District and a Yellowstone campground
(0 km); the worst were a divided highway in Louisiana (1,606 km) and a backlit
freeway in New York (1,492 km) — both of which could be almost anywhere.

Two things the implementation has to get right:

- **Exclude the same day.** Consecutive clips are the next few minutes of the
  same road: near-identical and a mile apart. Left in, every clip scores as
  perfectly locatable. Date is a rough proxy for "the same drive."
- **Use iterative scan.** The day filter is applied during the HNSW scan, so
  without `hnsw.iterative_scan` a candidate whose neighbourhood is mostly
  same-day comes back with a handful of neighbours, sometimes zero, and its
  median is noise. It's also about 5x faster than the exhaustive fallback.
- **Score several moments per clip.** A clip is ~3 minutes of driving with ~32
  frame embeddings, and its moments vary in quality far more than clips do —
  glare into the lens, a truck filling the windscreen, nine-tenths blown-white
  sky are bad *moments* in clips that have good ones. One clip's four sampled
  moments came back spanning 15.7 to 58.3 median km. `--per-clip` is the knob
  (default `4`); a clip contributes only its best-ranked moment, because
  selection takes each clip once and rank order decides which. The cost is
  sublinear — four moments each on a 400-clip pool is 7.7s against 3.2s for one —
  and the encode, which is the slow half, still cuts one clip per round.

Rounds are then taken from the better-scoring half of the pool, best-ranked
first, skipping any clip too close to one already taken or from a state that has
filled its share. `--keep-fraction` sets how much of the pool is in contention;
`--min-spacing` and `--state-cap` are what keep the set from piling into the
roads the van drove most.

### The second signal: distinctiveness

Geographic spread alone rewards a frame it shouldn't. Empty two-lane blacktop,
fog and open sky come back with a tight neighbour cluster — not because the
image carries location signal, but because the corpus drove that same road on
several other days, so its near-identical twins really are all in one place. The
score says *locatable*; a human player has nothing to work with.

The same neighbours separate the two cases for free, as the **mean cosine
distance** to them: near-duplicates sit low, a frame with no visual twin
anywhere in the corpus sits high. It is close to independent of the geographic
spread (Spearman ρ ≈ 0.19 over a 400-clip pool), so it is real extra
information rather than the same measurement twice.

So `rank()` folds it into the ordering, weighted by `--distinctiveness` (default
`0.25`). That weight is the only thing acting on this signal, deliberately: a
percentile floor discarding the generic tail *as well* was measured against it
over three seeds and moved nothing the weight was not already moving, while
costing worst-case locatability on two of the three. One mechanism per signal.

Sorting the ranked set by this signal is the clearest way to see what it does. At
the top: a ferry deck, a signed visitor centre, a harbour full of boats, a
grocery storefront. At the bottom: five near-identical shots of empty Wyoming
highway, a foggy field, and a frame that is mostly cloud.

**Known limitation:** the score measures locatability *within
this corpus*. A landmark visited on exactly one day has its real visual matches
excluded along with the rest of that day, so it can score as generic and be
dropped. Rescuing those by their high cosine distance was the original reason to
compute it, and the frames say don't: the highest-cosine clips the geographic
filter had dropped are a mix — a downtown skyline and a picket-fence New England
street worth keeping, but also a rain-blurred windshield, a parking-lot wall and
two frames that are nine-tenths sky. Distinctive and *guessable* are not the same
thing, and there is no evidence yet for a rule that separates them. Frequently
visited areas don't have the problem at all.

## How a round is built

`video_coords` carries the coordinate the dashcam printed onto each frame — read
off the HUD by OCR upstream, when the corpus was processed — plus a confidence in
each clip's whole track, and `videos` carries the reverse-geocoded state. That
track is what enumerates a clip's candidate moments; an embedding from
`frame_embeddings` is fetched for each one to score it. So a round is a (clip,
moment, truth coords) triple whose answer describes the frame the player is shown
rather than the three minutes it sits in — the clip's single lat/lng, used
instead, put a median 1,317 m between the pin and the road on screen.

**The clips must be cropped.** The dashcam burns a HUD across the bottom of
every frame reading `49 MPH W71.606763 N42.822437` plus the date — the answer,
in text, on screen. `make_rounds.py` crops that strip off and `check.py` fails
if a clip ever ships uncropped, since the failure is otherwise invisible: the
game still runs, it's just trivially cheatable. That check runs on whatever
machine generated the set rather than in CI, which never sees the media — `task
clips:push` will not upload a set that fails it.

## Not built yet

- **Reordering a day**, moving a round between dates or within one. Rejecting a
  bad round out of a date is built (see *Previewing a day*); putting a chosen
  round into a chosen slot is not.
- **A round set with no source clip in common with the pre-server-side sets.**
  Those sets carried their coordinates in a committed manifest, which is in this
  repo's history (see *The rows a round set is* above). 34 of the current 300
  rounds are cut from a clip one of them used, and truth was clip-level — so
  those 34 are worth only as much as the player's disinclination to run
  `git log`. Fine for a beta; a regeneration closes it.

## Licence

Two licences, because there are two kinds of thing here.

The **code** is MIT — `LICENSE`, unchanged and unqualified. Take it.

The **footage** is not licensed at all: the clips a round serves, the frames cut
from them and the derived stills are **© A Dana Life, all rights reserved** —
`LICENSE-CONTENT`. Published so the game can be played, and for nothing else.
Licences, commercial ones included, are available by asking.

The asymmetry is the point. The code is worth more shared than withheld; the
footage is a year of driving that cannot be re-shot and is the reason the game
can exist. The two directions are also not equally reversible — **a licence, once
given, cannot be withdrawn from copies already distributed** — so a permissive
grant is a one-way door, while starting closed leaves both moves available.

Two consequences worth stating rather than leaving to be discovered:

- **The split is by kind, not by directory.** A clip carries its terms wherever
  it is — in R2, on the page, saved off the page. Every clip also carries the
  credit in its container metadata and a mark in its corner (see *How a round is
  built*), so a file that has travelled away from here still says where it came
  from.
- **The history predates the split.** Round sets used to be committed, so
  dashcam frames are in this repo's git history from a time when `LICENSE` was
  the only licence here. Nothing retroactively relicenses those objects. The
  media stopped being committed in [#53](https://github.com/adanalife/guessr/pull/53),
  so nothing new joins them.
