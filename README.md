# Guessr

GeoGuessr, but every round is a frame from the A Dana Life dashcam corpus —
a year of driving the United States in 2018.

Five rounds a day, the same five for everyone, with a spoiler-free share string
at the end. Practice rounds are unlimited.

The game is static files. `make_rounds.py` does all the work up front (query the
corpus metadata, extract frames, write a manifest); `web/` is then a plain
directory anyone can serve or drop on a CDN. No backend, no API keys — the map
is Leaflet over OpenStreetMap tiles.

## Play locally

```sh
task rounds   # needs the corpus mounted + kubectl access to the tripbot DB
task check    # validates the round set
task test     # daily draw + round-set swap; needs neither
task serve    # http://localhost:8000
```

`task serve` binds all interfaces, so a phone on the tailnet can reach it at
`http://<this-machine>:8000`. Round generation is the only step with
dependencies; `web/` on its own is a static directory anyone can host.

## Deploying

Two tiers, two Cloudflare Pages projects:

| | URL | Deploys when | Workflow |
|---|---|---|---|
| staging | [stage.guessr.dana.lol](https://stage.guessr.dana.lol) | every merge to `main` | `staging.yml` |
| production | [guessr.dana.lol](https://guessr.dana.lol) | a `vX.Y.Z` tag ships | `release.yml` |

So `main` is always live *somewhere* to look at, and the game people play only
moves when a release goes out. Cutting one means merging the standing
`chore(main): release X.Y.Z` PR — release-please tags it and dispatches
`release.yml` at the tag. Nothing else promotes to production.

Both deploys stamp `web/version.json` and copy `CHANGELOG.md` in beside it, so
the About panel can name the running build and show what changed — the tag on
production, `main@<sha>` on staging. Neither file is committed, so a locally
served copy just shows no version.

The Pages projects and the DNS records are terraform, in the `infra` repo under
`terraform/prod-1/cloudflare-pages-guessr.tf` and `terraform/core/route53.tf`.

`web/` holds `index.html`, its scripts (`daily.js`, `zoom.js`,
`changelog.js`), the two share-card assets (`og.jpg`,
`favicon.svg`), and the round set — `rounds.json` plus ~300 frames under
`frames/`. The round set is committed even though `task rounds` regenerates it,
because regenerating needs the corpus mounted and database access and the
deploy has neither. Regenerating rewrites about 27 MB of JPEGs, so do it
deliberately.

Because that set is tracked, a regeneration rewrites ~300 files of tracked
content and the next merge deploys the result — so **a generation that fails
leaves the current one alone.** `task rounds` builds into `web/.staging`, runs
`check.py` against *that*, and moves it into place only if it passes. A run with
the corpus unmounted or the database unreachable leaves the working tree exactly
as it was rather than deleting the frames it was about to replace, and the
rejected set is left in `web/.staging` to look at.

`og.jpg` is the link preview, and the link preview is the whole distribution
mechanism: this game spreads by people pasting a URL. It's a hand-picked frame
with the title set over it, made once and committed:

```sh
magick web/frames/<frame>.jpg \
  -gravity North -crop 1280x672+0+0 +repage -resize 1200x630! \
  \( -size 1200x300 -define gradient:vector='0,0 0,300' \
     gradient:'rgba(0,0,0,0.62)-rgba(0,0,0,0)' \) -gravity North -composite \
  -font Helvetica-Bold -fill white -gravity NorthWest \
  -pointsize 96 -annotate +60+52 'Guessr' \
  -font Helvetica -pointsize 36 -fill '#dfe6ea' \
  -annotate +64+168 'GeoGuessr, but every round is a dashcam frame' \
  -annotate +64+214 'from a year of driving the United States' \
  -quality 88 -strip web/og.jpg
```

Swapping the frame means re-running that and updating `og:image:alt`. Keep it
1200x630 — that's the aspect every scraper crops to.

## Development

```sh
pre-commit install   # wires up both the file hooks and the commit-msg check
```

Commits and PR titles follow [Conventional Commits](https://www.conventionalcommits.org).
PRs squash-merge, so the PR title becomes the subject in history and is what
release-please reads to compute the next version.

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
rounds are chosen](#how-rounds-are-chosen)), and the header shows the current
round's band as three dots — `●●○`. The ordering runs on the drawn five, never
on the pool, so it can't change *which* rounds a day draws. The band cutoffs
(32 km and 120 km) are the terciles of the shipped set.

`test_daily.js` covers the draw, because it fails invisibly: if it stops being
deterministic, every player simply gets different rounds, nothing errors, and
the share string quietly stops meaning anything. The test pins determinism,
independence from the order `rounds.json` was written in, that the ramp reorders
the five without changing which five, and that a DST boundary doesn't skip or
repeat a day number.

The pool needs to stay comfortably larger than five times however many days you
want before rounds repeat; `task check` reports that number. Regenerating
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

**The frames must be cropped.** The dashcam burns a HUD across the bottom of
every frame reading `49 MPH W71.606763 N42.822437` plus the date — the answer,
in text, on screen. `make_rounds.py` crops that strip off and `check.py` fails
if a frame ever ships uncropped, since the failure is otherwise invisible: the
game still runs, it's just trivially cheatable.

## Not built yet

- **Per-frame ground truth.** The HUD holds exact coords for the frame being
  shown, which is finer than the clip-level lat/lng scored against today.
  Reading it means OCR'ing the strip before cropping it.
- **Video rounds.** A few seconds of motion beats a still, and motion is the
  whole character of the source material.
- **A leaderboard.** Needs scoring moved server-side first: `rounds.json`
  currently ships the truth coordinates to the browser, so any score a client
  reports is unverifiable. The fix is for the client to post its guess and the
  server to hold the answers and return the score.
