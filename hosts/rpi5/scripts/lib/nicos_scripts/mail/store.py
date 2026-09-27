"""The mail store: every message classified once, ever.

The digest used to re-classify the whole unread backlog every morning, so
nothing accumulated — no way to score Jev, no way to know a message had already
been surfaced three days running. A row per message fixes both.

`now` is a parameter everywhere so the tests do not depend on the clock.
"""

import hashlib
import os
import sqlite3

SIGNALS = ("needs_reply", "deadline", "money", "security", "human_sender",
           "bulk", "urgency")

SCHEMA = """
CREATE TABLE IF NOT EXISTS messages (
  key         TEXT PRIMARY KEY,
  account     TEXT NOT NULL,
  source      TEXT NOT NULL DEFAULT '',
  thread      TEXT NOT NULL DEFAULT '',
  sender      TEXT NOT NULL DEFAULT '',
  subject     TEXT NOT NULL DEFAULT '',
  date        TEXT NOT NULL DEFAULT '',
  url         TEXT NOT NULL DEFAULT '',
  first_seen  TEXT NOT NULL,
  last_seen   TEXT NOT NULL,
  state       TEXT NOT NULL DEFAULT 'unread',
  needs_reply REAL, deadline REAL, money REAL, security REAL,
  human_sender REAL, bulk REAL, urgency REAL,
  rank        REAL,
  disposition TEXT,
  disposition_confidence REAL,
  jev_model   TEXT,
  classified_at TEXT,
  input_tokens  INTEGER NOT NULL DEFAULT 0,
  surfaced_count INTEGER NOT NULL DEFAULT 0,
  last_surfaced  TEXT,
  verdict     TEXT
);
CREATE INDEX IF NOT EXISTS messages_pending
  ON messages(classified_at) WHERE classified_at IS NULL;
CREATE INDEX IF NOT EXISTS messages_rank ON messages(state, rank DESC);
"""


def connect(path):
    parent = os.path.dirname(path)
    if parent:
        os.makedirs(parent, exist_ok=True)
    conn = sqlite3.connect(path)
    conn.row_factory = sqlite3.Row
    conn.executescript(SCHEMA)
    return conn


def imap_key(sender, subject, date):
    """Stable id for an IMAP message.

    The UID cannot be used: it is scoped to UIDVALIDITY and churns whenever the
    folder is reshuffled, which would duplicate the row and reset its history.
    """
    raw = "|".join((sender or "", subject or "", date or ""))
    return "imap:" + hashlib.sha1(raw.encode("utf-8", "replace")).hexdigest()


def key_for(env):
    """Provider id for Gmail, content hash for everything else."""
    if (env.get("source") or "").startswith("gmail:") and env.get("id"):
        return "gmail:" + str(env["id"])
    return imap_key(env.get("from"), env.get("subject"), env.get("date"))


def upsert_seen(conn, envelopes, now, state="unread"):
    """Record that these messages exist. Returns the keys touched.

    Classification columns are never written here, so a message already
    classified keeps its verdict and its counters across re-fetches.
    """
    keys = []
    for env in envelopes:
        key = key_for(env)
        keys.append(key)
        conn.execute(
            """INSERT INTO messages
                 (key, account, source, thread, sender, subject, date, url,
                  first_seen, last_seen, state)
               VALUES (?,?,?,?,?,?,?,?,?,?,?)
               ON CONFLICT(key) DO UPDATE SET
                 last_seen = excluded.last_seen,
                 state     = excluded.state,
                 url       = excluded.url""",
            (key, env.get("account", ""), env.get("source", ""),
             env.get("thread", ""), env.get("from", ""), env.get("subject", ""),
             env.get("date", ""), env.get("url", ""), now, now, state),
        )
    conn.commit()
    return keys


def unclassified(conn, limit=None):
    sql = "SELECT * FROM messages WHERE classified_at IS NULL ORDER BY date DESC"
    if limit:
        sql += f" LIMIT {int(limit)}"
    return [dict(r) for r in conn.execute(sql)]


def save_classification(conn, key, result, model, now):
    sig = result.get("signals") or {}
    conn.execute(
        f"""UPDATE messages SET
              {", ".join(f"{s} = ?" for s in SIGNALS)},
              rank = ?, disposition = ?, disposition_confidence = ?,
              jev_model = ?, classified_at = ?, input_tokens = ?
            WHERE key = ?""",
        tuple(sig.get(s) for s in SIGNALS)
        + (result.get("rank"), result.get("disposition"),
           result.get("disposition_confidence"), model, now,
           int((result.get("usage") or {}).get("input_tokens") or 0), key),
    )


def reconcile(conn, accounts, seen_keys, now):
    """Mark messages that stopped appearing as `gone`.

    Without this the nag fires forever on mail that was archived or deleted the
    day after it was surfaced.
    """
    if not accounts:
        return 0
    seen = set(seen_keys)
    rows = conn.execute(
        "SELECT key FROM messages WHERE state != 'gone' AND account IN (%s)"
        % ",".join("?" * len(accounts)),
        tuple(accounts),
    ).fetchall()
    stale = [r["key"] for r in rows if r["key"] not in seen]
    for key in stale:
        conn.execute(
            "UPDATE messages SET state = 'gone', last_seen = ? WHERE key = ?",
            (now, key),
        )
    conn.commit()
    return len(stale)


def live_ranked(conn):
    """Classified, still-present messages, best first — the digest's input."""
    return [dict(r) for r in conn.execute(
        "SELECT * FROM messages WHERE state = 'unread' AND classified_at IS NOT NULL "
        "ORDER BY rank DESC, date DESC, subject ASC")]


def mark_surfaced(conn, keys, now):
    for key in keys:
        conn.execute(
            "UPDATE messages SET surfaced_count = surfaced_count + 1, "
            "last_surfaced = ? WHERE key = ?", (now, key))
    conn.commit()


def spend(conn):
    row = conn.execute(
        "SELECT COUNT(*) n, COALESCE(SUM(input_tokens),0) t FROM messages "
        "WHERE classified_at IS NOT NULL").fetchone()
    return {"classified": row["n"], "input_tokens": row["t"]}
