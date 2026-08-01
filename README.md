# Guessr

GeoGuessr, but every round is a frame from the A Dana Life dashcam corpus —
a year of driving the United States in 2018.

The game is static files. `make_rounds.py` does all the work up front (query the
corpus metadata, extract frames, write a manifest); `web/` is then a plain
directory anyone can serve or drop on a CDN. No backend, no API keys — the map
is Leaflet over OpenStreetMap tiles.

## Play locally

```sh
task rounds   # needs the corpus mounted + kubectl access to the tripbot DB
task check    # validates the round set
task serve    # http://localhost:8000
```

`task serve` binds all interfaces, so a phone on the tailnet can reach it at
`http://<this-machine>:8000`. Round generation is the only step with
dependencies; `web/` on its own is a static directory anyone can host.

Nothing in `web/` is committed except `index.html` — the frames are extracted
from the dashcam corpus and the manifest is rebuilt, so both are gitignored.

## Development

```sh
pre-commit install   # wires up both the file hooks and the commit-msg check
```

Commits and PR titles follow [Conventional Commits](https://www.conventionalcommits.org).
PRs squash-merge, so the PR title becomes the subject in history and is what
release-please reads to compute the next version.

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

**Known limitation:** the score measures locatability *within this corpus*. A
landmark visited on exactly one day has its real visual matches excluded along
with the rest of that day, so it can score as generic and be dropped — a false
negative on what would be a great round. Frequently-visited areas don't have
this problem. Reading the mean cosine distance alongside the geographic spread
would catch it, since a one-off landmark has no close visual neighbours at all.

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
- **A difficulty rating per round.** `median_km` is already in the manifest and
  is a reasonable proxy — it just isn't surfaced in the UI or used to order a
  game from easy to hard.
- **Video rounds.** A few seconds of motion beats a still, and motion is the
  whole character of the source material.
- **A daily round**, shared by everyone, so scores are comparable.
