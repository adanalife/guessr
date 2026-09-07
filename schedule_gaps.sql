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
-- The seed is unconditional, so the horizon always has at least one row: it is
-- checked even when MAX(date) is behind it or the table is empty, which is the
-- exhausted case, and its first date is one the site actually serves.
--
-- Still-open dates forward only, and the seed comes from the game's own
-- closing rule rather than from a midnight. A date runs until D+1 12:00 UTC
-- (playWindow in web/daily.js), so it is closed exactly once date('now') has
-- passed that, which puts the oldest open date 12 hours back -- and up to three
-- dates are open at once, so no single midnight is the boundary. Seeding from
-- date('now') instead skipped the whole Americas evening: from 00:00 UTC until
-- the date rolled over locally, the horizon started at tomorrow and a date
-- people were still playing could be short or missing with nothing reporting it.
--
-- A closed date is what stays excluded. It has been played and cannot be
-- fixed, so counting it would leave every caller permanently unhappy and
-- therefore unread; an open one drops out on its own the moment it closes.
WITH RECURSIVE want(date) AS (
  SELECT date('now', '-12 hours')
  UNION ALL
  SELECT date(date, '+1 day') FROM want
   WHERE date < (SELECT MAX(date) FROM round_days)
)
SELECT want.date AS date, COUNT(round_days.date) AS n
  FROM want LEFT JOIN round_days ON round_days.date = want.date
 GROUP BY want.date
 ORDER BY want.date;
