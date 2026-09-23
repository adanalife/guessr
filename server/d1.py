"""The `db` seam over a Cloudflare D1 binding, for the Python Worker.

Same four methods as `Sqlite`, so every handler runs on D1 unchanged. The
Workers SDK wraps `env.DB` and converts D1's results itself: a row arrives as a
`dict` subclass (`JsDict`), a missing row as None, a result's `results`/`meta`
as keys. So nothing here calls `.to_py()` -- that raises on an SDK-converted
value -- and results are read by key, which a plain dict in a test also has.

ponytail: None arguments are passed to `bind` as-is. Whether the SDK carries
them to D1 as SQL NULL, not `undefined` (which D1 refuses), is checked by the
first staging deploy's contract run; convert here if it does not.
"""


class D1:
    def __init__(self, binding):
        self.binding = binding

    def _statement(self, sql: str, args: tuple):
        return self.binding.prepare(sql).bind(*args)

    async def execute(self, sql: str, *args) -> int:
        """Runs a write and returns how many rows it changed."""
        result = await self._statement(sql, args).run()
        return result["meta"]["changes"]

    async def fetchone(self, sql: str, *args) -> dict | None:
        row = await self._statement(sql, args).first()
        return dict(row) if row is not None else None

    async def fetchall(self, sql: str, *args) -> list[dict]:
        result = await self._statement(sql, args).all()
        return [dict(row) for row in result["results"]]

    async def batch(self, statements: list[tuple]) -> list[int]:
        """D1's batch is one transaction, as Sqlite.batch is: a caller whose
        second statement assumes the first ran depends on that."""
        results = await self.binding.batch(
            [self._statement(sql, tuple(args)) for sql, *args in statements]
        )
        return [r["meta"]["changes"] for r in results]
