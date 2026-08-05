-- The structure the game runs on: what rounds exist, which date plays which of
-- them, and what a player scored. The *rows* come from elsewhere -- a round set
-- fills `rounds` and `round_days`, players fill `plays` -- but every table
-- definition is here.
--
-- Kept apart from the generated rounds.sql / answers.sql for that reason: those
-- are written by make_rounds.py, gitignored (answers.sql is the answer key, and
-- this is a public repo) and re-pushed on every regeneration, while this file is
-- hand-written, tracked, and pushed once per database. Folding them together
-- would mean a table of player scores whose definition only existed on whichever
-- laptop last built a round set.
--
-- So `schema:*:push` comes first on a fresh database. A rounds.sql pushed into
-- one that never got this fails loudly on a missing table, which is the right
-- way round.
--
-- Idempotent, so `task schema:{local,stage,prod}:push` is safe to re-run.

-- The pool: every round ever generated, and everything about one that is not its
-- location. This is what web/rounds.json used to be, moved out of the deploy --
-- a round set can now change without shipping the site, which is the whole point
-- of the table existing.
--
-- Deliberately carries NO lat/lng. The answers live one table over, so the
-- endpoint that hands a browser its five rounds physically cannot leak a
-- coordinate; that separation used to be manifest-versus-database and is now
-- table-versus-table.
--
-- Rows are never deleted. A round is ~0.5 MB of R2 against a 10 GB free tier, so
-- there is no pressure that would make forgetting one attractive, and a played
-- date has to stay reconstructable.
CREATE TABLE IF NOT EXISTS rounds (
  -- clips/<slug>-<milliseconds>.mp4 -- the moment is in the name, so a rebuild
  -- lands the same footage at the same URL. Also the R2 object key, and what
  -- `plays` and `answers` join on.
  image TEXT PRIMARY KEY,
  -- Locatability: the median distance from this frame's true position to those
  -- of its nearest neighbours in embedding space. Low means the frame carries
  -- real location signal. It orders the easy-to-hard ramp within a day.
  median_km REAL NOT NULL,
  -- Distinctiveness: mean cosine distance to those same neighbours. Low means
  -- the clip has near-identical twins elsewhere in the corpus.
  mean_cos REAL NOT NULL,
  -- Which generation run produced this round, so a bad batch can be found again.
  batch TEXT NOT NULL,
  -- queued (generated, not yet given a date) | scheduled | rejected.
  --
  -- Nothing writes 'rejected' yet -- /admin is the phase that adds the verb. The
  -- column is here now rather than then because the alternative is an ALTER
  -- against two live databases, and because "not in round_days" is NOT a
  -- substitute: once a reject exists, the next generation run has to be able to
  -- tell a round nobody has scheduled yet from one somebody threw out.
  status TEXT NOT NULL DEFAULT 'queued',
  -- The provenance a rebuild needs: which corpus clip, and which moment within
  -- it. source_ts_sec is an offset into the ORIGINAL recording and clip_ts_sec
  -- into the corpus cut ffmpeg was handed; they are equal for the 97% of clips
  -- that were never trimmed, and it is the source one that survives a re-trim.
  -- Without these a deleted clip is gone rather than re-cuttable.
  slug TEXT NOT NULL,
  source_ts_sec REAL NOT NULL,
  clip_ts_sec REAL NOT NULL,
  -- How wide the truth actually is, in metres: the stretch of road the van
  -- covers while the round plays. Drawn on the reveal so a player who recognised
  -- the street can see they were inside it.
  radius_m REAL NOT NULL,
  created_at TEXT NOT NULL DEFAULT (datetime('now'))
);

-- The schedule: what a given date's game IS, and in what order.
--
-- This replaces a seeded shuffle that both the page and the scorer recomputed
-- from the pool. Two things change by making it a stored fact rather than a
-- function. A regeneration can no longer reshuffle a day somebody is halfway
-- through -- the rows for an open date simply already exist. And a daily player
-- stops seeing repeats: under a reshuffling draw the same round came round again
-- roughly every other game by day 90, where a schedule hands out each round once.
CREATE TABLE IF NOT EXISTS round_days (
  date TEXT NOT NULL,              -- YYYY-MM-DD, the date whose game this is
  position INTEGER NOT NULL,       -- 1..5, the order the player sees
  image TEXT NOT NULL REFERENCES rounds (image),
  PRIMARY KEY (date, position)
);

-- Each round is played on exactly one date. This is the constraint that will
-- announce the corpus running out: five a day is 1,825 rounds a year against
-- ~4,400 clips, of which perhaps half clear the quality bar. When a generation
-- run cannot fill its horizon, this index is why -- and relaxing it (the same
-- clip at a different moment) is a one-line change.
CREATE UNIQUE INDEX IF NOT EXISTS round_days_once ON round_days (image);

-- Where a round actually was. The other half of the split: `rounds` is what a
-- browser may be told and this is what it may not, so /api/day reads one table
-- and /api/score is the only thing that ever reads the other.
--
-- The rows are seeded from the gitignored answers.sql (`task answers:*:push`) --
-- they are the answer key, and this is a public repo. The *definition* belongs
-- here with every other one, so a fresh database has somewhere to put them
-- before a round set has ever been generated for it.
CREATE TABLE IF NOT EXISTS answers (
  image TEXT PRIMARY KEY,
  lat REAL NOT NULL,
  lng REAL NOT NULL,
  state TEXT NOT NULL,
  filmed TEXT NOT NULL
);

-- One row per player per round per date: the record of a daily play, and the
-- leaderboard's entire storage. Both boards are one query over this.
--
-- It exists because scoring on its own is stateless: with no record of a play, a
-- client can score the same round over and over and keep the best number, and a
-- board on top of that ranks whoever re-guessed most, not who guessed best.
CREATE TABLE IF NOT EXISTS plays (
  -- The calendar date of the round set played, YYYY-MM-DD. The date itself
  -- rather than the day number, so a re-epoch or an off-by-one in dayNumber()
  -- cannot silently re-map history. `Guessr #N` stays a display label derived
  -- from it.
  date TEXT NOT NULL,
  -- Opaque, minted into localStorage on first play. NOT the handle: two players
  -- who both type "Jason" are two players, and keying on the name would read the
  -- second one's play as a replay of the first's and drop it. NOT the IP either
  -- -- NAT collapses a household into one player, CGNAT splits one phone into
  -- several across a day, and an address stored beside a typed name turns a
  -- storage disclosure into a personal-data one.
  player_id TEXT NOT NULL,
  image TEXT NOT NULL,
  -- Both, so a replay can be answered with the score that was actually recorded
  -- rather than a fresh distance beside a stale point total.
  km REAL NOT NULL,
  points INTEGER NOT NULL,
  -- A display label, nullable: a browser that cannot keep localStorage has no
  -- name to send, and a play still belongs on the board without one.
  handle TEXT,
  played_at TEXT NOT NULL DEFAULT (datetime('now')),
  -- First write wins, which is the whole point of the table. As the primary key
  -- rather than a separate unique index, so the uniqueness and the lookup that
  -- serves a replay are the same structure.
  PRIMARY KEY (date, player_id, image)
);

-- The daily board is the top of one date; the monthly board sums a date prefix.
-- Both start from a date scan, so one index over (date, points) serves them.
CREATE INDEX IF NOT EXISTS plays_by_date_points ON plays (date, points DESC);

-- The name on a board row is a different access path, which the index above
-- cannot serve: it seeks a player's most recent non-null handle across every
-- date they have played, so there is no date to scan from. Without an index on
-- player_id alone that seek is a full table scan, once per board row -- and the
-- boards are polled continuously to feed the stream overlay, on two separate
-- cache keys that the 60s response cache cannot collapse. That came to ~8.7M
-- rows read a day against a few hundred rows of stored data -- inside the Workers
-- Paid allowance, so the cost of it was wasted work rather than money, but the
-- ratio is the thing to notice: reads scale with plays x board rows x poll rate,
-- so it grows with the game while the data does not.
-- test_leaderboard.mjs asserts the query plan still uses it.
CREATE INDEX IF NOT EXISTS plays_by_player_recent ON plays (player_id, played_at);
