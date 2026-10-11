-- When a player said a round's coordinates looked wrong.
--
-- On `plays` rather than a table of its own: a report is a fact about one play
-- -- this player, this date, this round -- and the play row is the only proof
-- the reporter saw the clip.
--
-- It is also the rate limit. `UPDATE ... WHERE reported_at IS NULL` reports a
-- play exactly once, so a loop costs one indexed write rather than a run of
-- webhook posts, and five plays a day is all a player can report.
ALTER TABLE plays ADD COLUMN reported_at TEXT;
