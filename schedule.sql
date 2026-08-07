-- How far ahead the schedule runs, and what there is to schedule with.
--
-- A tier goes dark the day after its last scheduled date, and nothing about
-- that failure is loud: the pool can be full, the media served, the answers
-- seeded, and a player still meets an empty day because no `round_days` row
-- names it. So the state worth watching is not "are there rounds" but "how
-- many days stand between today and the end of the schedule" -- the number an
-- unattended generator reads to decide whether to top up, and the number a
-- human reads to know whether anything is urgent. Read-only, so
-- `task schedule:prod` is safe against production.

-- The horizon in one row. `days_left` counts from today (UTC, which is the
-- grid dates open on) to the last scheduled date.
SELECT
  MAX(date) AS last_day,
  CAST(julianday(MAX(date)) - julianday(date('now')) AS INTEGER) AS days_left
FROM round_days;

-- The pool by status. `queued` is the tail reject-and-replace draws from --
-- at zero, a reject costs the furthest-out day whole.
SELECT status, COUNT(*) AS rounds
FROM rounds
GROUP BY status
ORDER BY status;

-- Scheduled rounds placed on no date. Zero unless a schedule write went wrong
-- or a promotion stranded rounds; either way these are reviewed rounds going
-- unused, and the first place to look when a day needs filling.
SELECT COUNT(*) AS unplaced
FROM rounds r
WHERE r.status = 'scheduled'
  AND NOT EXISTS (SELECT 1 FROM round_days d WHERE d.image = r.image);

-- Each day from today forward and its round count. A game is five rounds, so
-- any other number here is a day that will not serve correctly.
SELECT date, COUNT(*) AS rounds
FROM round_days
WHERE date >= date('now')
GROUP BY date
ORDER BY date;
