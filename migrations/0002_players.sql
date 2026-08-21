-- The people behind the player ids, as far as anyone here knows them.
--
-- A row exists only for a player somebody has named by hand -- a friend, a
-- regular from the stream, whoever turned up at the top of a board and is worth
-- recognising next time. Everyone else plays unnamed and always will; this is
-- not a users table and nothing writes to it but an operator.
--
-- Two columns because they answer two different questions, and only one of them
-- is anybody else's business:
--
--   alias -- what anything showing this player should call them, replacing the
--            name they drew for themselves. It is published, so it goes on a
--            stream overlay the moment it is set.
--   note  -- who they actually are, for whoever is reading the stats. Served by
--            nothing. It exists so that recognising a player does not require
--            publishing what you recognised them by.
--
-- Keyed on player_id rather than on a play, because the id is what persists: a
-- handle is rerolled and a play is one round on one date, while the id is the
-- same string across every game that browser has ever finished.
CREATE TABLE players (
  player_id TEXT PRIMARY KEY,
  alias TEXT,
  note TEXT,
  updated_at TEXT NOT NULL DEFAULT (datetime('now'))
);
