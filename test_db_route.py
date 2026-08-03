#!/usr/bin/env python3
"""Check which route the scoring query takes to Postgres. `python3 test_db_route.py`

Two places run this script and they reach the same database in opposite ways. A
laptop has no route to it at all -- it sits in the cluster behind no ingress --
so the only way in is to exec a psql that is already inside. A pod in that
cluster has the Service and does not have the RBAC to exec into anything.

Getting the branch backwards fails in a way that reads like a broken database:
in-cluster it is `kubectl: not found` or an RBAC refusal, and on the laptop it is
a connection to nothing. Both branches are pinned here so neither depends on
noticing at 25 minutes into a generation.
"""

import os

from make_rounds import psql_invocation

SAVED = {k: os.environ.get(k) for k in ("DATABASE_HOST", "DATABASE_PORT")}
SAVED |= {
    k: os.environ.get(k) for k in ("DATABASE_PASS", "DATABASE_USER", "DATABASE_DB")
}


def env(**kwargs):
    for key in SAVED:
        os.environ.pop(key, None)
    os.environ.update({k: v for k, v in kwargs.items() if v is not None})


# No DATABASE_HOST is the laptop: exec into the pod, in the named namespace, and
# pass nothing to libpq -- the psql that connects is the one inside the pod.
env()
argv, environ = psql_invocation("stage-1-data", pool=400, k=25, per_clip=4)
assert argv[:6] == ["kubectl", "-n", "stage-1-data", "exec", "-i", "postgres-0"], argv
assert argv[6] == "--" and argv[7] == "psql", argv
assert "PGHOST" not in environ, "a host libpq would use on a route where it cannot"

# DATABASE_HOST is in-cluster: psql runs here and talks to the Service, so
# kubectl must not appear at all.
env(DATABASE_HOST="postgres.stage-1-data.svc", DATABASE_PASS="s3cret")
argv, environ = psql_invocation("stage-1-data", pool=400, k=25, per_clip=4)
assert argv[0] == "psql", argv
assert "kubectl" not in argv, argv
assert environ["PGHOST"] == "postgres.stage-1-data.svc", environ["PGHOST"]
assert environ["PGPASSWORD"] == "s3cret"
# 5432 without being asked, so a Service on the default port needs no config.
assert environ["PGPORT"] == "5432", environ["PGPORT"]

env(DATABASE_HOST="db", DATABASE_PORT="15432")
assert psql_invocation("ns", 1, 1, 1)[1]["PGPORT"] == "15432"

# The query itself is the same either way -- same parameters, same stdin script.
# A route that quietly scored a different pool would be the worst version of this.
env()
laptop, _ = psql_invocation("stage-1-data", pool=400, k=25, per_clip=4)
env(DATABASE_HOST="db")
cluster, _ = psql_invocation("stage-1-data", pool=400, k=25, per_clip=4)
assert laptop[laptop.index("psql") :] == cluster, (laptop, cluster)

# The user and database default to what the laptop path has always passed, so an
# unset environment is not a behaviour change.
env()
argv, _ = psql_invocation("stage-1-data", 400, 25, 4)
assert argv[argv.index("-U") + 1] == "tripbot", argv
assert argv[argv.index("-d") + 1] == "tripbot", argv

env(**SAVED)
print("ok: the database route follows DATABASE_HOST, and the query does not change")
