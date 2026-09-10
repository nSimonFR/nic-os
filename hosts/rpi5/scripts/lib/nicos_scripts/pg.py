"""Read-only Postgres SELECTs over the local socket, as the postgres superuser.

Peer auth: the invoking service user generally cannot read the per-app
`*-pg-password` agenix secret (those are postgres-owned) and does not need to
for a read. `run` is the injectable seam — tests hand in a fake and never touch
a socket.

`-tAF\\x1f` gives tuples-only, unaligned, US-separated output, so a value
containing a comma, a tab or a pipe still parses. Callers get a list of lists
of strings; an empty result is an empty list, never None.
"""

SEP = "\x1f"


def psql_rows(run, sql, db, runuser="runuser", psql="psql"):
    out = run([runuser, "-u", "postgres", "--", psql,
               "-d", db, "-tAF" + SEP, "-c", sql])
    return [line.split(SEP) for line in out.splitlines() if line.strip()]
