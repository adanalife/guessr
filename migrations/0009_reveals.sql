-- What the place a player guessed looks like.
--
-- One still per ~2 km grid cell the corpus drove through, each the frame nearest
-- its cell's centre, so /api/score can answer "you guessed here, and this is what
-- *here* looks like" with one indexed lookup. Written by reveals.py, which cuts
-- the stills; the media is in R2 under reveals/, served by
-- functions/reveals/[name].js.
--
-- Separate from `answers` on purpose. Those are the rounds, and this is the whole
-- corpus thinned to a grid -- rows here say nothing about which moments a game
-- plays, and `image` names a cell rather than a clip, so collecting them through
-- practice guesses cannot be joined back to a round's name.
CREATE TABLE reveals (
  image TEXT PRIMARY KEY,
  lat REAL NOT NULL,
  lng REAL NOT NULL
);

-- The lookup is a latitude band, then a longitude filter over what is left: a
-- band 50 km tall holds a few hundred of the ~8,000 rows, so the second column
-- would buy nothing a scan of those does not.
CREATE INDEX reveals_lat ON reveals (lat);
