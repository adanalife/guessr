-- Every date in a tier's horizon with the number of rounds scheduled on it,
-- including the dates holding none. Read-only. Read by verify_days.sh, which
-- applies the per-game threshold, and by test_verify_days.py.
--
-- want() is the horizon enumerated rather than read back from the table,
-- because the schedule failures that matter most are dates with no rows at
-- all: an exhausted horizon, or a gap inside one. Grouping the table's own
-- rows cannot see either -- a date holding nothing produces no group, so it
-- comes back absent instead of as a zero, and a caller checking for short days
-- passes over a schedule that has run out entirely.
--
-- The seed is unconditional, so today is always one of the rows: it is checked
-- even when MAX(date) is behind it or the table is empty, which is the
-- exhausted case, and today is the date the site actually serves.
--
-- Dates from today forward only. A past date has already been played and
-- cannot be fixed, so counting it would leave every caller permanently unhappy
-- and therefore unread.
WITH RECURSIVE want(date) AS (
  SELECT date('now')
  UNION ALL
  SELECT date(date, '+1 day') FROM want
   WHERE date < (SELECT MAX(date) FROM round_days)
)
SELECT want.date AS date, COUNT(round_days.date) AS n
  FROM want LEFT JOIN round_days ON round_days.date = want.date
 GROUP BY want.date
 ORDER BY want.date;
