# Guessr

GeoGuessr, but every round is a few seconds of the A Dana Life dashcam corpus —
a year of driving the United States in 2018.

Five rounds a day, the same five for everyone, with a spoiler-free share string
at the end. Practice rounds are unlimited.

The game is static files plus one endpoint. `make_rounds.py` does all the work up
front (query the corpus metadata, cut the clips, write a manifest); `web/` is
then a plain directory of HTML, JS and mp4. The map is Leaflet over
OpenStreetMap tiles.

A round plays on a loop and can be paused — the button in the frame's corner, or
the space bar. Motion is what places a scene; a still is what lets you read the
sign in it.

The endpoint is `POST /api/score`, a Cloudflare Pages Function, and it exists
because the answers can't ship to the browser. `web/rounds.json` names each
round's clip and how hard it is, and nothing else — the coordinates live in a D1
database the client can't read, so a player learns where a clip was taken only
by committing a guess and getting the score back.

## Play locally

```sh
task rounds   # needs the corpus mounted + kubectl access to the tripbot DB
task check    # validates the round set
task clips:push  # uploads the media to R2, without which a deploy has none
task test     # daily draw, scoring, round-set swap; needs neither
task dev      # http://localhost:8000, with scoring
task serve    # http://localhost:8000, static only — guesses don't score
```

`task dev` runs `wrangler pages dev` against a local D1 — `schema.sql` applied
and `answers.sql` seeded — so guessing works end to end, including the record a
daily play leaves behind. `task serve` is a plain
`http.server` for everything else — layout, zoom, the About panel — and is
enough for most UI work; a guess in it fails with "could not reach the scorer".
Both bind all interfaces, so a phone on the tailnet can reach them at
`http://<this-machine>:8000`.

Round generation is the only step with real dependencies.

## Deploying

Three tiers, two Cloudflare Pages projects:

| | URL | Deploys when | Workflow |
|---|---|---|---|
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

The Pages projects and the DNS records are terraform, in the `infra` repo under
`terraform/prod-1/cloudflare-pages-guessr.tf` and `terraform/core/route53.tf`.

`web/` holds `index.html`, its scripts (`daily.js`, `zoom.js`,
`changelog.js`), `manifest.json`, the icon and share-card assets (`favicon.svg`,
`apple-touch-icon.png`, `icon-512.png`, `og.jpg`), the ET Book faces under
`et-book/`, and the round set — `rounds.json` plus ~300 clips under `clips/`.

**Only the manifest is committed.** A round set is ~150 MB of mp4 and this repo
is public, so committing one would add that to git history on every
regeneration, permanently. `web/clips/` is gitignored and the media lives in an
R2 bucket instead; the three deploy workflows pull it into `web/` before
uploading. `rounds.json` has to stay in git regardless, because
`functions/api/score.js` imports it at build time — that is what makes the five
rounds the server checks a daily play against provably the five the page handed
out.

`clips.sh` moves the media both ways, and names the object after a hash of the
manifest. That is deliberate: under a stable name, regenerating would overwrite
the tarball that production — still on an older release, with an older manifest
— pulls on its next deploy, and production would come back up naming clips the
bucket no longer holds. Content-addressing makes a manifest and its media
inseparable, and makes "the clips were never pushed" a failed deploy rather than
a game of black panes. Nothing in the bucket is ever deleted, for the same
reason: an old tarball is what some deployed manifest still points at.

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

`functions/` holds the scoring endpoint. It is not served: Pages routes
`functions/api/score.js` to `/api/score`, and `_scoring.mjs` is skipped by the
router (leading underscore) so the handler can import it.

The handler also imports `web/daily.js` and `web/rounds.json` — the same draw and
the same pool the page plays from, bundled into the worker at build time. That is
what lets it check that a posted round really is one of that date's five without
storing a schedule anywhere: both sides run the same function over the same data
from the same commit, so they cannot disagree unless the deploy is internally
inconsistent. It is also why `daily.js` is an ES module rather than a plain
script, and why the page's inline script is `type="module"`.

### The answers

`task rounds` writes two files *outside* `web/`, and neither is committed:
`answers.json` (every round's lat/lng/state/date) and `answers.sql` (the same
thing as a D1 seed script). `web/` is the entire deployed surface, so anything in
there is fetchable; and this is a public repo, so a committed answer key is the
same leak as a manifest full of coordinates.

They reach the deployed game through D1:

```sh
task answers:stage:push   # adanalife-guessr-answers-staging
task answers:prod:push    # adanalife-guessr-answers
```

**A regenerated round set is unplayable until that push runs** — every guess
comes back "unknown round", because the rounds deployed are ones the answers
table has never heard of. `task rounds` prints the reminder on the way out,
alongside the other push a new set needs: `task clips:push`, without which the
rounds have no footage to show in the first place.

The databases are terraform, in `infra` alongside the Pages projects, and each
tier has its own so a regeneration on one doesn't strand the other.

### The tables the game owns

The same D1 also holds `plays`, one row per player per round per date — the
record of a daily result, and the whole storage behind the leaderboard. Its DDL
is hand-written in `schema.sql` rather than generated, and applied once per
database:

```sh
task schema:stage:push
task schema:prod:push
```

It is kept out of `answers.sql` because the two change on completely different
clocks: `answers.sql` is regenerated and re-pushed with every round set, while
`schema.sql` is idempotent DDL. Folding them together would put the definition of
a table of player scores inside a gitignored file that only exists on whichever
laptop last built a round set.

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
fetches on its own schedule. The board being unreachable costs a rotation slot
and nothing else.

### Names on the stream

Rows carry the player's alias, and it is safe to render as stored because of
where it comes from: a curated wordlist, so the review happens when the name is
*made* rather than after it is typed. There is no moderation queue because there
is nothing a stranger chose. A play with no name at all — one recorded before
aliases existed, or from a browser that can't keep `localStorage` — renders as
`anonymous` and still places.

If typed names ever land, an allowlist lands with them and joins into the board
query; until then it would be a table with nothing to hold.

One thing this does *not* buy yet: the round sets published before scoring moved
server-side had their coordinates in `rounds.json`, and that file is in this
repo's git history. Until the set is regenerated, the answers are still one
`git log` away for anyone who looks — so the endpoint is the mechanism, not yet
the guarantee. A leaderboard needs the regeneration first.

A regeneration replaces every clip under `web/clips/` and rewrites the
manifest that gets committed — so **a generation that fails leaves the current
one alone.** `task rounds` builds into `web/.staging`, runs `check.py` against
*that*, and moves it into place only if it passes. A run with the corpus
unmounted or the database unreachable leaves the working tree exactly as it was
rather than deleting the clips it was about to replace, and the rejected set is
left in `web/.staging` to look at.

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

The recipe names a corpus clip and a timestamp, which is what makes it
reproducible. It used to name `web/frames/<frame>.jpg` from whatever round set
was current, and the frame it wanted had long since left the set — so the recipe
built a *new* card rather than the committed one, and the only way to change
anything was to composite onto the existing image. Keying it to the corpus fixes
that for good: a round set is regenerable, and the corpus clip behind this frame
is not going anywhere.

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

```
Guessr #1
🟩🟨🟩⬜🟧
18,204 / 25,000
```

Finishing writes the day to `localStorage`, so today's round can't be replayed
for a better result. Practice mode draws at random and is unlimited.

Both modes then order their five rounds easy to hard by `median_km` (see [How
rounds are chosen](#how-rounds-are-chosen)). The ordering runs on the drawn five,
never on the pool, so it can't change *which* rounds a day draws. The ramp is
felt, not shown — nothing in the header rates the round you are looking at.

`test_daily.mjs` covers the draw, because it fails invisibly: if it stops being
deterministic, every player simply gets different rounds, nothing errors, and
the share string quietly stops meaning anything. The test pins determinism,
independence from the order `rounds.json` was written in, that the ramp reorders
the five without changing which five, and that a DST boundary doesn't skip or
repeat a day number. It matters twice over now that `/api/score` draws from the
same module to check a play: a draw that shifted would have the server rejecting
rounds the page had just handed out.

### When a day is open

A date is playable from midnight in the earliest timezone on Earth to midnight in
the latest — 10:00 UTC the day before until 12:00 UTC the day after, 50 hours, so
everyone gets their own full day. Up to three dates are therefore open at once,
which is why a board on the stream has to name the date it is showing rather than
assume there is a single "today".

`/api/score` enforces both edges on a daily play. The close is what lets a board
be final; the open is the only thing stopping someone playing next week today,
since the draw is deterministic and computed on the client. A refused play comes
back as a 403 with a distinct message, and the page treats a 4xx as final rather
than inviting a retry that cannot work.

**Rounds repeat sooner than the pool size suggests.** A day reshuffles the whole
pool and takes five; it does not deal the pool out into non-overlapping days. So
repeats begin within the first week or two whatever the pool size, and what a
bigger pool buys is how *often* one comes round again. At 300 rounds, a player
who plays all of the next 90 days meets 233 of them and sees a repeat about
every other round; `task check` reports both numbers for the current set.

Dealing days out of an unused slice instead would genuinely delay the first
repeat, at the cost of a draw that has to know which days have already been
played — worth it only if anyone ever plays long enough to mind. Regenerating
`rounds.json` reshuffles future dailies, since the draw depends on which rounds
exist — worth doing between days rather than mid-day.

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

Rounds are then *sampled* from the better-scoring half rather than taken
strictly best-first, which drops the featureless rounds while keeping the set
varied. `--keep-fraction` is the knob.

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

So the bottom slice of the pool by mean cosine distance is discarded before
ranking. `--drop-generic` is the knob (default `0.15`); the cut is a percentile
rather than an absolute distance, so it survives a change of corpus or embedding
model. On a 400-clip pool that drops about 40 of the ~200 clips the geographic
score would have kept, and admits about 10 in their place.

Sorting the kept set by this signal is the clearest way to see what it does. At
the top: a ferry deck, a signed visitor centre, a harbour full of boats, a
grocery storefront. At the bottom: five near-identical shots of empty Wyoming
highway, a foggy field, and a frame that is mostly cloud.

**Known limitation, unchanged:** the score still measures locatability *within
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

`videos` carries a lat/lng and a reverse-geocoded state per clip, and
`frame_embeddings` carries sampled timestamps within each clip. Joining them
gives a pool of (clip, timestamp, truth coords) — one round each. Ground truth
is clip-level, which is accurate to a couple of miles, since a clip is about
three minutes of driving.

**The clips must be cropped.** The dashcam burns a HUD across the bottom of
every frame reading `49 MPH W71.606763 N42.822437` plus the date — the answer,
in text, on screen. `make_rounds.py` crops that strip off and `check.py` fails
if a clip ever ships uncropped, since the failure is otherwise invisible: the
game still runs, it's just trivially cheatable. That check runs on the laptop
now rather than in CI, which never sees the media — `task clips:push` will not
upload a set that fails it.

## Not built yet

- **Per-frame ground truth.** The HUD holds exact coords for the frame being
  shown, which is finer than the clip-level lat/lng scored against today.
  Reading it means OCR'ing the strip before cropping it.
- **The board on the stream.** Everything on this side of it exists: results are
  recorded and verified, names are collected and moderated, and
  `/api/leaderboard` serves both boards. What's left is tripbot fetching it —
  two new `leaderboardKind`s in its rotation, which currently splits one
  five-minute slot three ways and would need re-weighting for five.
- **A round set whose answers aren't in git.** The sets published before scoring
  moved server-side had their coordinates in `rounds.json`, and that file is in
  this repo's history (see *The answers* above), so a score is only worth as much
  as the player's disinclination to run `git log`. Fine for a beta; the set gets
  regenerated before this is something people compete at.
