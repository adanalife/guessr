-- Where the pin actually went, alongside how far off it was.
--
-- `km` and `points` say a guess was 43 km out and worth 4,120. They cannot say
-- it was dropped in the wrong Portland, which is the half of a result anybody
-- who played wants to see, and the half nothing can reconstruct: a radius is
-- not a point. Until now it existed only in the browser that dropped the pin,
-- so a player who cleared their storage or opened the game on a second device
-- had no record of their own games at all.
--
-- Nullable, and permanently so: every play recorded before this migration has no
-- coordinates and never will. Anything drawing one of those rounds has its score
-- and no line on the map, which is what the end-of-game board already does for a
-- save from before guesses were kept.
ALTER TABLE plays ADD COLUMN guess_lat REAL;
ALTER TABLE plays ADD COLUMN guess_lng REAL;
