-- What the game already knows about how it is being played, asked out loud.
--
-- Every daily guess is written to `plays` (migrations/0001_initial_schema.sql),
-- so the questions worth
-- asking about play -- how many people, how far they got, which frames are
-- brutal, whether anyone came back -- are queries over a table that already
-- exists rather than a second thing to instrument. Read-only, so
-- `task stats:prod` is safe against production.
--
-- This is the "how did they do" half. The "did anyone visit at all" half is
-- Cloudflare Web Analytics, whose beacon Pages injects at the edge rather than
-- serving from this repo -- so it is absent from web/index.html and present on
-- the deployed page. It counts the people who never guessed, whom nothing here
-- can see.
--
-- Practice rounds are absent by design: /api/score only records a guess that
-- names a date, so everything below is the daily game.

-- Per day: who showed up and how far they got. `finished` is the number that
-- matters -- a player who guessed once and left is counted in `players` too.
--
-- Counting distinct players and not rows: the subquery emits one row per guess
-- with its player's round count beside it, so summing the predicate counts five
-- rows for every player who finished.
SELECT
  date,
  COUNT(DISTINCT player_id) AS players,
  COUNT(*) AS guesses,
  COUNT(DISTINCT CASE WHEN rounds = 5 THEN player_id END) AS finished,
  ROUND(AVG(points), 0) AS avg_points,
  ROUND(AVG(km), 0) AS avg_km
FROM (
  SELECT date, player_id, points, km,
         COUNT(*) OVER (PARTITION BY date, player_id) AS rounds
  FROM plays
  WHERE date <= date('now')
)
GROUP BY date
ORDER BY date DESC
LIMIT 30;

-- Drop-off. How many players reached each round of the five, all-time: the
-- shape of this is whether the game is too long, and round 1 -> round 2 is the
-- steepest cliff a puzzle game has.
SELECT rounds AS reached, COUNT(*) AS players
FROM (
  SELECT date, player_id, COUNT(*) AS rounds
  FROM plays
  WHERE date <= date('now')
  GROUP BY date, player_id
)
GROUP BY rounds
ORDER BY rounds;

-- Retention. Players by how many separate days they have played; the 1 bucket
-- is everyone who tried it once and never came back.
SELECT days_played, COUNT(*) AS players
FROM (
  SELECT player_id, COUNT(DISTINCT date) AS days_played
  FROM plays
  WHERE date <= date('now')
  GROUP BY player_id
)
GROUP BY days_played
ORDER BY days_played;

-- The hardest frames, which is the difficulty ramp being marked by the people
-- playing it rather than by the locatability score that picked them. A round
-- everyone misses by a thousand kilometres is a bad round, not a hard one.
SELECT image, COUNT(*) AS guesses, ROUND(AVG(km), 0) AS avg_km, ROUND(AVG(points), 0) AS avg_points
FROM plays
WHERE date <= date('now')
GROUP BY image
HAVING guesses >= 3
ORDER BY avg_km DESC
LIMIT 10;
