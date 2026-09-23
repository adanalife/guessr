-- Short codes that let a new device join a player it has no id for.
--
-- /api/link needs both player ids in the same hand, and the only way to get the
-- far one there is a URL fragment opened in the right browser. That route is
-- closed to a Home Screen install (its own storage, not the browser's) and to
-- the native app, neither of which can open a link into itself. A code is the
-- other direction: the device with the history asks for one, a person reads it
-- off one screen and types it into the other, and the server -- the only party
-- that sees both ids -- runs the merge and tells the new device who to be.
--
-- A table rather than a signed token, because a code short enough to type is
-- far too short to carry a signature: it can only be a lookup key, and the
-- lookup has to live somewhere. Rows are meant to be gone within minutes --
-- claimed, or swept once past `expires_at` by the next issue or claim -- so
-- this is never more than a handful of rows and holds nothing a play does not.
CREATE TABLE link_codes (
  code TEXT PRIMARY KEY,
  player_id TEXT NOT NULL,
  -- ISO 8601 UTC to the second ('2026-09-23T12:34:56Z'), written by SQLite's
  -- own clock in both runtimes, so expiry is a string comparison against the
  -- same format and the handlers carry no clock of their own.
  expires_at TEXT NOT NULL
);
