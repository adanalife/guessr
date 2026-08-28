-- Make the reveal's dependency a rule the database enforces.
--
-- A recorded play's reveal reads truth from `answers` by image and never
-- consults `rounds` (functions/api/score.js), so an `answers` row that `plays`
-- references is load-bearing: delete it and the recap and share screens for an
-- already-played round break, silently and permanently. Nothing said so. The
-- table has no foreign keys at all today, and the only thing standing between
-- a tidy-up of orphaned answer rows and lost history was whoever wrote the
-- DELETE noticing.
--
-- The FK is `plays.image -> answers(image)`, the join the reveal actually
-- depends on. Deliberately NOT `plays -> rounds`: plays sit on images with no
-- `round_days` row, some predating the `rounds` table entirely, and that
-- constraint would refuse the data already stored. Deliberately NOT
-- `answers -> rounds` either: the answer rows from the hand-published sets that
-- predate `rounds` would violate it, and they are the only record those sets
-- left. They are staying.
--
-- No ON DELETE clause, so the default NO ACTION applies: an answer row a play
-- references cannot be deleted at all. A cascade would be the wrong reading of
-- what this protects -- the play is the history, not a detail of the answer --
-- and it would also turn `INSERT OR REPLACE INTO answers` into a statement that
-- silently deletes plays, since REPLACE deletes before it inserts. The seed
-- script upserts instead, so it depends on neither, but the hazard is worth
-- knowing before anyone adds a cascade here.
--
-- SQLite cannot ADD CONSTRAINT, so `plays` is rebuilt. D1 runs a migration in a
-- transaction, so a row that violates the constraint rolls the whole thing back
-- rather than leaving a half-built table. Check for those first, read-only:
--
--   SELECT COUNT(*) FROM plays p
--     LEFT JOIN answers a ON a.image = p.image
--    WHERE a.image IS NULL;
--
-- It must be 0. A nonzero count means plays exist whose answer row is already
-- gone, and those have to be settled before this can apply.
CREATE TABLE plays_new (
  date TEXT NOT NULL,
  player_id TEXT NOT NULL,
  image TEXT NOT NULL REFERENCES answers (image),
  km REAL NOT NULL,
  points INTEGER NOT NULL,
  handle TEXT,
  played_at TEXT NOT NULL DEFAULT (datetime('now')),
  guess_lat REAL,
  guess_lng REAL,
  PRIMARY KEY (date, player_id, image)
);

INSERT INTO plays_new (date, player_id, image, km, points, handle, played_at, guess_lat, guess_lng)
SELECT date, player_id, image, km, points, handle, played_at, guess_lat, guess_lng FROM plays;

DROP TABLE plays;
ALTER TABLE plays_new RENAME TO plays;

-- Both indexes are recreated by hand: DROP TABLE takes its indexes with it, and
-- the rename does not bring the originals back. Same definitions as 0001 --
-- test_leaderboard.mjs asserts the board query still plans onto the second one.
CREATE INDEX IF NOT EXISTS plays_by_date_points ON plays (date, points DESC);
CREATE INDEX IF NOT EXISTS plays_by_player_recent ON plays (player_id, played_at);
