"""The page's constants against the server's rules.

web/ and server/ share no import, so the numbers they have to agree on are
checked here rather than trusted: every alias the wordlists can make fits the
handle column /api/score records, and the share string's trophy band is still
the kilometre it was measured as.

    uv run --project api python test_rules_web.py   # or `task test`
"""

import json
import re
from pathlib import Path

from server import rules

HERE = Path(__file__).resolve().parent

# A word added later that pushed a pair over MAX_HANDLE would not fail anywhere
# obvious -- the play would record nameless and the player would show as the
# placeholder, having done nothing wrong. Exhaustive rather than sampled: it is
# 2,401 pairs and the point is that no combination is a surprise.
words = json.loads((HERE / "web" / "alias.json").read_text())
longest = max(
    (f"{a} {n}" for a in words["adjectives"] for n in words["nouns"]), key=len
)
assert len(longest) <= rules.MAX_HANDLE, (
    f"{longest!r} is {len(longest)} chars; the board's column holds {rules.MAX_HANDLE}"
)

# The top band's cutoff in web/share.js is a distance written in points, and
# nothing in share.js can tell that it stopped being one. Widen MAP_SIZE_KM or
# reshape the curve and 4989 quietly becomes some other radius -- a trophy for
# eight km, or one nobody can reach -- while share.js's own checks still pass,
# because they only see that the table is internally consistent. 5 km was the
# next candidate and covers twice as many guesses, so a bar that has drifted out
# that far is the wrong bar even if it is still a round number.
share = (HERE / "web" / "share.js").read_text()
trophy = int(re.search(r"BANDS = \[\s*(?://.*\n\s*)*\{ min: (\d+)", share).group(1))
assert rules.score_for(1) >= trophy, (
    f"a guess 1 km out scores {rules.score_for(1)}, under the {trophy} bar"
)
assert rules.score_for(1.05) < trophy, "the bar is looser than the kilometre it claims"
assert rules.score_for(5) < trophy, "a guess 5 km out earns the trophy"

print(
    f"ok: {len(words['adjectives']) * len(words['nouns'])} aliases fit {rules.MAX_HANDLE} chars"
)
print(f"ok: the {trophy}-point trophy is still a one-kilometre guess")
