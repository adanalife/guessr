// A stand-in for D1's binding, over node:sqlite, so an endpoint handler can be
// run by a test instead of only by clicking through `task dev`.
//
// Cheap because D1 *is* SQLite and node ships SQLite: the only thing between the
// two is the shape of the API. D1 defers execution to .run()/.first()/.all(),
// reports row counts under meta.changes, and returns rows from .all() wrapped in
// { results }. That is the whole adapter.
//
// What it deliberately is not: a model of D1. Its network errors, its statement
// cache, its consistency behaviour and its limits are all absent, so anything
// resting on those still belongs in `task dev` against a real local D1. What it
// buys is the half of a handler that is neither the SQL nor the pure logic --
// the guards, the status codes and the order things happen in -- which was
// otherwise reachable by no test at all.
//
// Underscore-prefixed to match functions/_scoring.mjs, and so `task test`'s
// test_*.mjs glob doesn't try to run it as a test.
import { readdirSync, readFileSync } from 'node:fs';
import { DatabaseSync } from 'node:sqlite';

// Every migration, concatenated in the order wrangler applies them.
//
// Tests build their database the way a real one is built, rather than from a
// single file that describes the shape. That matters more than it sounds: a
// migration that only works when run after another one, or a table that was
// added to the baseline instead of to a new migration, both pass a
// read-one-file test and fail against a deployed database.
export function schema() {
  return readdirSync('migrations')
    .filter(f => f.endsWith('.sql'))
    .sort()
    .map(f => readFileSync(`migrations/${f}`, 'utf8'))
    .join('\n');
}

class Statement {
  constructor(db, sql, args = []) {
    this.db = db;
    this.sql = sql;
    this.args = args;
  }

  bind(...args) {
    return new Statement(this.db, this.sql, args);
  }

  run() {
    const { changes } = this.db.prepare(this.sql).run(...this.args);
    return { meta: { changes: Number(changes) } };
  }

  // D1 answers with null for no row; node:sqlite answers with undefined.
  first() {
    return this.db.prepare(this.sql).get(...this.args) ?? null;
  }

  all() {
    return { results: this.db.prepare(this.sql).all(...this.args) };
  }
}

// Returns the binding an `env` hands a handler, with `.db` alongside so a test
// can seed rows and read them back without going through the endpoint.
export function d1(schema) {
  const db = new DatabaseSync(':memory:');
  db.exec(schema);
  return {
    db,
    prepare: sql => new Statement(db, sql),
    // A batch is one transaction: link.js depends on that, since its second
    // statement assumes the first ran.
    batch(statements) {
      db.exec('BEGIN');
      try {
        const out = statements.map(s => s.run());
        db.exec('COMMIT');
        return out;
      } catch (e) {
        db.exec('ROLLBACK');
        throw e;
      }
    },
  };
}

// The request shape a Pages Function is handed. `body` undefined sends no JSON
// at all, which is the malformed-payload path.
export function post(body) {
  return {
    json: async () => {
      if (body === undefined) throw new SyntaxError('no body');
      return body;
    },
  };
}
