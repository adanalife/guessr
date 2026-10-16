-- The owner's own label for a player, and a star to pick them out of a board.
--
-- Both private, like `note`: served only by the owner-only admin routes, and
-- never joined into anything public. `alias` is the published name; this is
-- the one the owner reads, so a friend can be "Phil" on the console without
-- "Phil" going on the stream overlay.
ALTER TABLE players ADD COLUMN private_name TEXT;
ALTER TABLE players ADD COLUMN starred INTEGER NOT NULL DEFAULT 0;
