// What to call a player, as one SQL expression both the boards and a shared
// recap are built from.
//
// The rule has two halves and they have to stay in one piece: an operator-set
// alias wins, and failing that the last name the player drew for themselves.
// Written out twice it would drift, and the drift is invisible until the day a
// board and a recap of that same day disagree about who won it.
//
// Underscore-prefixed, so Pages leaves it out of the routing table.

// What renders for a play carrying no name -- one recorded before aliases
// existed, or from a browser that cannot keep localStorage and so cannot hold a
// place on a board anyway. The score still counts and still places, so a board
// is never short a row.
export const PLACEHOLDER = 'anonymous';

// `player` is whatever SQL refers to the player id in the caller's statement: a
// column when this is selected per row, a numbered parameter when it is looked
// up for one player. Numbered rather than `?`, because the id appears twice
// below and an anonymous placeholder would want binding twice.
//
// Both halves are point lookups -- `players` by its primary key, `plays` by the
// `plays_by_player_recent` index -- so this stays cheap enough to select per
// board row. test_leaderboard.mjs asserts that second half still uses the index.
//
// `handle IS NOT NULL` because a play can be nameless. Without it, one such play
// would blank a name the player still has on every other row.
export const nameExpr = player => `COALESCE(
    (SELECT n.alias FROM players n WHERE n.player_id = ${player}),
    (SELECT h.handle
       FROM plays h
      WHERE h.player_id = ${player} AND h.handle IS NOT NULL
      -- played_at is second-resolution, so two rounds committed inside one
      -- second tie; rowid breaks it by insert order.
      ORDER BY h.played_at DESC, h.rowid DESC
      LIMIT 1))`;
