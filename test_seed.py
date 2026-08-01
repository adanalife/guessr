#!/usr/bin/env python3
"""Check the seed plumbing in make_rounds.py. Run with `python3 test_seed.py`.

`--seed` reads as a safety net -- rebuild with the same seed and get the same
round set back -- and the round set is committed and deployed, so that net is
what makes a bad regeneration recoverable. Two things it rests on are pinned
here: the seed maps into the narrow range `setseed` accepts, and the `setseed`
statement travels in the same psql invocation (and therefore the same Postgres
session) as the pool query it applies to.
"""

from make_rounds import SCORE_SQL, pg_seed, score_sql

# Pinned literals, not just self-comparison: the seed has to mean the same thing
# in a run next month as it did today, and Python salts string hashing per
# process, so a mapping built on hash() would pass a within-process check and
# still fail the only case that matters.
assert pg_seed(42) == -0.09938470086064966
assert pg_seed(20260801) == -0.9541600775942137

# In range, for seeds well past what a human would type. Postgres rejects
# anything outside [-1, 1] outright.
for seed in (0, 1, 2, 42, 1234, 20260801, -7, 2**31, 2**63, -(2**63)):
    value = pg_seed(seed)
    assert -1.0 <= value <= 1.0, f"{seed} maps to {value}, outside setseed's range"

# Adjacent seeds have to land far apart. Scaling an integer into [-1, 1] would
# put 1 and 2 a rounding error from each other, which is the failure that makes
# `--seed 1` and `--seed 2` risk drawing the same pool.
nearby = [pg_seed(s) for s in range(1, 21)]
assert len(set(nearby)) == len(nearby), "distinct seeds collapsed onto one value"
assert min(abs(a - b) for a in nearby for b in nearby if a != b) > 1e-3, nearby

# No seed means no setseed: the draw stays as random as it was, and the query
# text is untouched.
assert score_sql(None) == SCORE_SQL
assert "setseed" not in score_sql(None)

# A seed prepends exactly one setseed, ahead of the pool query, in the same
# string -- one string is one psql invocation is one session, which is the whole
# reason this is a query-text property rather than a separate statement.
seeded = score_sql(42)
assert seeded.count("setseed") == 1, seeded
assert seeded.startswith("SELECT setseed(-0.09938470086064966);\n"), seeded
assert seeded.endswith(SCORE_SQL), "the scoring query was altered, not just seeded"
assert seeded.index("setseed") < seeded.index("ORDER BY random()"), (
    "setseed lands after the draw it is supposed to pin"
)

print("ok: seeds map into setseed's range, and travel with the query they seed")
