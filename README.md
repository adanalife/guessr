# Guess the Road

GeoGuessr, but every round is a frame from the A Dana Life dashcam corpus —
a year of driving the United States in 2018.

The game is static files. `make_rounds.py` does all the work up front (query the
corpus metadata, extract frames, write a manifest); `web/` is then a plain
directory anyone can serve or drop on a CDN. No backend, no API keys — the map
is Leaflet over OpenStreetMap tiles.

## Play locally

```sh
python3 make_rounds.py -n 60   # needs the NAS mounted + kubectl access
python3 check.py               # validates the round set
python3 -m http.server -d web 8000
```

Then open <http://localhost:8000>.

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
- **Round difficulty.** Sampling is uniform over clips, so the distribution
  follows the trip itself — California and Wyoming dominate, and a fair number
  of rounds are featureless interstate. Scoring frames by how distinctive they
  are would make for better rounds.
- **Video rounds.** A few seconds of motion beats a still, and motion is the
  whole character of the source material.
- **A daily round**, shared by everyone, so scores are comparable.
