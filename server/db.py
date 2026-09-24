"""The database seam every handler talks through.

Three async methods, sqlite-shaped, because every host guessr might run on speaks
SQLite: D1 on Cloudflare, a file on a VPS, `:memory:` in a test. Handlers take an
object with this shape and never import a driver, so moving host is a new adapter
rather than a rewrite.

Async because D1's binding is: a handler written against a synchronous seam could
never run on Cloudflare. The sqlite3 adapter is async only in signature.
"""

import sqlite3
from pathlib import Path

MIGRATIONS = Path(__file__).resolve().parent.parent / "migrations"


class Sqlite:
    def __init__(self, path: str = ":memory:"):
        self.conn = sqlite3.connect(path, isolation_level=None)
        self.conn.row_factory = sqlite3.Row
        # D1 enforces foreign keys on every query and cannot turn them off.
        self.conn.execute("PRAGMA foreign_keys = ON")

    def migrate(self) -> "Sqlite":
        """Replays every migration in the order wrangler applies them."""
        for f in sorted(MIGRATIONS.glob("*.sql")):
            self.conn.executescript(f.read_text())
        return self

    async def execute(self, sql: str, *args) -> int:
        """Runs a write and returns how many rows it changed."""
        return self.conn.execute(sql, args).rowcount

    async def fetchone(self, sql: str, *args) -> dict | None:
        row = self.conn.execute(sql, args).fetchone()
        return dict(row) if row else None

    async def fetchall(self, sql: str, *args) -> list[dict]:
        return [dict(row) for row in self.conn.execute(sql, args)]

    async def batch(self, statements: list[tuple]) -> list[int]:
        """Runs (sql, *args) writes in one transaction and returns each rowcount.
        D1's batch is also one transaction, and a caller whose second statement
        assumes the first ran depends on that."""
        with self.conn:
            self.conn.execute("BEGIN")
            return [self.conn.execute(sql, args).rowcount for sql, *args in statements]
