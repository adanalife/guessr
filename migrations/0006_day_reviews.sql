-- Which days somebody has actually looked at.
--
-- Rejecting a round has been possible since #100, but nothing recorded the
-- other half of a review: a day nobody opened and a day reviewed and found
-- fine are the same rows, so "is the schedule reviewed out to the horizon" has
-- never been a question the database could answer.
--
-- A table of its own rather than a column on `round_days`, because the fact is
-- about the *day* and that table is one row per round -- five copies of one
-- timestamp, disagreeing the moment a reject rewrites one of them. A date with
-- no row here is unreviewed, which is the right default for every day already
-- scheduled.
--
-- Deliberately not a gate on anything. Nothing refuses to publish an unreviewed
-- day, because review is meant to stay possible and never required -- the same
-- property the three-day generation lead exists to give. This makes the state
-- visible; what to do about an unreviewed day stays a person's call.
CREATE TABLE day_reviews (
  date TEXT PRIMARY KEY,
  -- Who is left out on purpose: Cloudflare Access already knows, and one
  -- operator reviewing his own game gains nothing from a column that would
  -- put an email address in a database the game reads from.
  reviewed_at TEXT NOT NULL DEFAULT (datetime('now'))
);
