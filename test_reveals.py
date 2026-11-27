"""Cover reveals.py's two pure halves: reading psql's rows, writing D1's.

Both fail by producing less rather than by erroring. A parser that mis-counts a
width skips every row and the run reports zero cells; a seed script over D1's
statement limit is refused whole, so a push lands none of ~8,000 rows. The
ffmpeg half needs the corpus and is covered by the aspect check inside
cut_still, the same assertion check.py runs over a round's clips.
"""

from reveals import ROWS_PER_STATEMENT, parse_cells, reveals_sql

out = "\n".join(
    [
        "SET",  # psql acknowledging a statement, not a row
        "2018_0514_120000_001\t42.5\t40.01\t-99.99\t2000\t-5000",
        "2018_0515_090000_004\t17.0\t48.0\t-119.7\t2400\t-5985",
        "",
    ]
)
cells = parse_cells(out)
assert [c["image"] for c in cells] == ["2000_-5000.jpg", "2400_-5985.jpg"], cells
assert cells[0]["ts"] == 42.5 and cells[0]["lat"] == 40.01 and cells[0]["lng"] == -99.99

# The name is the cell and only the cell. A slug in it would let a script join
# a still back to a round's `<slug>-<ms>.mp4` and read the answer off the pair.
for c in cells:
    assert c["slug"].split("_")[0] not in c["image"], c

# Chunked under D1's 100 KB statement limit, every row present exactly once.
many = [
    {"image": f"{i}_{-i}.jpg", "lat": 40 + i / 1e4, "lng": -100 - i / 1e4}
    for i in range(2 * ROWS_PER_STATEMENT + 1)
]
sql = reveals_sql(many)
statements = [s for s in sql.split(";\n") if s.strip()]
assert len(statements) == 3, len(statements)
assert all(len(s.encode()) < 100_000 for s in statements)
assert all(s.startswith("INSERT INTO reveals") for s in statements)
assert sum(s.count("_") for s in statements) == len(many)
assert "ON CONFLICT (image) DO UPDATE" in statements[0]
assert reveals_sql([]) == ""

print("ok: reveals.py reads cells by width and writes D1-sized upserts named by cell")
