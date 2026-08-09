"""The pending queue — verdicts that could not be reached yet.

A photo uploaded while beast is offline has no CLIP embedding, so the workflow
step cannot decide anything about it. The old behaviour was to wait 60s and then
answer "not food", which is a lie: the answer is *unknown*, and it was thrown
away. Given beast is usually offline, that lost most of the decisions.

So an undecidable asset is recorded here instead, and `drain` finishes the job
once Immich has embedded it. Same shape as Immich's own ML offload: the work
queues, waits for the GPU host, and completes when it returns.

SQLite rather than a JSON file because two processes write it — the sidecar on
every undecidable asset, the drainer when it resolves one. WAL mode so a drain
pass never blocks a live classify.
"""

import json
import sqlite3

SCHEMA = """
CREATE TABLE IF NOT EXISTS pending (
    assetId    TEXT PRIMARY KEY,
    profile    TEXT NOT NULL,
    threshold  REAL NOT NULL,
    albumIds   TEXT NOT NULL,
    enqueuedAt INTEGER NOT NULL,
    attempts   INTEGER NOT NULL DEFAULT 0
);
"""


def connect(path):
    conn = sqlite3.connect(path, timeout=30)
    conn.execute("PRAGMA journal_mode=WAL")
    conn.execute("PRAGMA busy_timeout=30000")
    conn.executescript(SCHEMA)
    conn.commit()
    return conn


def enqueue(conn, asset_id, profile, threshold, album_ids, now):
    """Record an undecidable asset. Idempotent on assetId.

    A re-trigger of the same asset (a metadata refresh, say) must not create a
    second row, but it should refresh the config — the workflow's threshold or
    target album may have been edited since.
    """
    conn.execute(
        """INSERT INTO pending (assetId, profile, threshold, albumIds, enqueuedAt)
           VALUES (?, ?, ?, ?, ?)
           ON CONFLICT(assetId) DO UPDATE SET
             profile=excluded.profile,
             threshold=excluded.threshold,
             albumIds=excluded.albumIds""",
        (asset_id, profile, float(threshold), json.dumps(list(album_ids)), int(now)),
    )
    conn.commit()


def pending(conn, limit=1000):
    rows = conn.execute(
        """SELECT assetId, profile, threshold, albumIds, enqueuedAt, attempts
           FROM pending ORDER BY enqueuedAt LIMIT ?""",
        (limit,),
    ).fetchall()
    return [
        {
            "assetId": r[0],
            "profile": r[1],
            "threshold": r[2],
            "albumIds": json.loads(r[3]),
            "enqueuedAt": r[4],
            "attempts": r[5],
        }
        for r in rows
    ]


def count(conn):
    return conn.execute("SELECT count(*) FROM pending").fetchone()[0]


def resolve(conn, asset_id):
    """Drop a decided asset. Called for match AND no-match alike — the queue
    holds undecided work, not unfiled work."""
    conn.execute("DELETE FROM pending WHERE assetId = ?", (asset_id,))
    conn.commit()


def bump(conn, asset_id):
    conn.execute("UPDATE pending SET attempts = attempts + 1 WHERE assetId = ?", (asset_id,))
    conn.commit()


def expire(conn, max_age_days, now):
    """Drop entries older than the cut-off, returning what was dropped.

    Without this the queue grows forever on assets that will never be embedded
    (deleted originals, formats the ML server rejects). Callers log the return
    value — a silently shrinking queue would hide a real problem.
    """
    cutoff = int(now) - int(max_age_days) * 86400
    rows = conn.execute(
        "SELECT assetId FROM pending WHERE enqueuedAt < ?", (cutoff,)
    ).fetchall()
    conn.execute("DELETE FROM pending WHERE enqueuedAt < ?", (cutoff,))
    conn.commit()
    return [r[0] for r in rows]


def drop_missing(conn, known_asset_ids, candidates):
    """Drop queued assets that no longer exist (deleted since being queued)."""
    gone = [a for a in candidates if a not in known_asset_ids]
    if gone:
        conn.executemany(
            "DELETE FROM pending WHERE assetId = ?", [(a,) for a in gone]
        )
        conn.commit()
    return gone
