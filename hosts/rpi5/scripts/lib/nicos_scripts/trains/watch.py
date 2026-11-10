#!/usr/bin/env python3
"""
hermes-train-watch: re-price every active train watch and print the alerts.

A watch is one origin/destination/date plus an alert rule. Each run searches
the sources, stores the best price (history for "when do prices move?"), and
prints a message only when a rule fires — silence is the steady state. stdout is
the Telegram message (see nicos_scripts/hermes/__init__.py).

Subcommands (add / list / remove / history) manage the watches by hand; Hermes
runs them through the cron script. No subcommand = the cron run.

Rules: `max_price` (alert at or under it) and/or `drop_pct` (alert when the best
price falls that much since the previous check). A watch with neither gets
drop_pct=10. After an alert, only a lower price alerts again.

Env: TRAIN_WATCH_DB, TRAIN_WATCH_SOURCES.
"""

import argparse
import json
import os
import re
import sqlite3
import sys
import urllib.error
from dataclasses import dataclass
from datetime import date, datetime
from pathlib import Path

from ..logs import logger
from ..secrets import env_str
from . import sources as src

# stderr: stdout is the delivered message.
log = logger("hermes-train-watch", lambda: sys.stderr)

DEFAULT_DB = "~/.hermes/workspace/train-watch/watch.sqlite3"
DEFAULT_DROP_PCT = 10.0

SCHEMA = """
CREATE TABLE IF NOT EXISTS watches (
    id TEXT PRIMARY KEY,
    origin TEXT NOT NULL,
    destination TEXT NOT NULL,
    date TEXT NOT NULL,
    sources TEXT NOT NULL,
    max_price REAL,
    drop_pct REAL,
    depart_after TEXT,
    depart_before TEXT,
    max_changes INTEGER NOT NULL DEFAULT 0,
    note TEXT NOT NULL DEFAULT '',
    created_at TEXT NOT NULL,
    last_alert_price REAL,
    active INTEGER NOT NULL DEFAULT 1
);
CREATE TABLE IF NOT EXISTS checks (
    id INTEGER PRIMARY KEY AUTOINCREMENT,
    watch_id TEXT NOT NULL REFERENCES watches(id) ON DELETE CASCADE,
    checked_at TEXT NOT NULL,
    best_price REAL,
    best_source TEXT,
    best_departs TEXT,
    n_trains INTEGER NOT NULL,
    errors TEXT NOT NULL DEFAULT ''
);
CREATE TABLE IF NOT EXISTS observations (
    check_id INTEGER NOT NULL REFERENCES checks(id) ON DELETE CASCADE,
    source TEXT NOT NULL,
    departs TEXT NOT NULL,
    arrives TEXT NOT NULL,
    price REAL,
    changes INTEGER NOT NULL,
    train TEXT NOT NULL
);
CREATE INDEX IF NOT EXISTS checks_by_watch ON checks(watch_id, checked_at);
"""


@dataclass(frozen=True)
class Config:
    db: str = DEFAULT_DB

    @classmethod
    def from_env(cls, env=None):
        return cls(db=os.path.expanduser(env_str("TRAIN_WATCH_DB", DEFAULT_DB, env)))


def connect(cfg):
    Path(cfg.db).parent.mkdir(parents=True, exist_ok=True)
    conn = sqlite3.connect(cfg.db)
    conn.row_factory = sqlite3.Row
    conn.execute("PRAGMA foreign_keys = ON")
    conn.executescript(SCHEMA)
    return conn


def _slug(*parts):
    return re.sub(r"[^a-z0-9]+", "-", src.norm("-".join(parts))).strip("-")


def _hhmm(value, label):
    if value in (None, ""):
        return None
    if not re.fullmatch(r"([01]\d|2[0-3]):[0-5]\d", value):
        raise ValueError(f"{label} doit être HH:MM, reçu {value!r}")
    return value


def add_watch(
    conn,
    origin,
    destination,
    day,
    *,
    max_price=None,
    drop_pct=None,
    depart_after=None,
    depart_before=None,
    max_changes=0,
    sources=None,
    note="",
    now=None,
):
    """Create a watch and return its row as a dict. Same route+date+window updates it."""
    try:
        when = date.fromisoformat(day)
    except ValueError:
        raise ValueError(f"date doit être YYYY-MM-DD, reçu {day!r}") from None
    now = now or datetime.now()
    if when < now.date():
        raise ValueError(f"{day} est dans le passé")
    chosen = list(sources or src.SOURCES)
    if bad := [s for s in chosen if s not in src.SOURCES]:
        raise ValueError(
            f"source inconnue : {', '.join(bad)} (attendu {', '.join(src.SOURCES)})"
        )
    if max_price is not None and max_price <= 0:
        raise ValueError("max_price doit être positif")
    if drop_pct is not None and not 0 < drop_pct < 100:
        raise ValueError("drop_pct doit être entre 0 et 100")
    if max_price is None and drop_pct is None:
        drop_pct = DEFAULT_DROP_PCT
    after, before = (
        _hhmm(depart_after, "depart_after"),
        _hhmm(depart_before, "depart_before"),
    )

    wid = _slug(origin, destination, day, after or "", before or "")
    conn.execute(
        """INSERT INTO watches (id, origin, destination, date, sources, max_price, drop_pct,
               depart_after, depart_before, max_changes, note, created_at)
           VALUES (?,?,?,?,?,?,?,?,?,?,?,?)
           ON CONFLICT(id) DO UPDATE SET sources=excluded.sources, max_price=excluded.max_price,
               drop_pct=excluded.drop_pct, max_changes=excluded.max_changes, note=excluded.note,
               last_alert_price=NULL, active=1""",
        (
            wid,
            origin,
            destination,
            day,
            ",".join(chosen),
            max_price,
            drop_pct,
            after,
            before,
            max_changes,
            note,
            now.isoformat(timespec="seconds"),
        ),
    )
    conn.commit()
    return get_watch(conn, wid)


def get_watch(conn, wid):
    row = conn.execute("SELECT * FROM watches WHERE id = ?", (wid,)).fetchone()
    if row is None:
        raise KeyError(f"watch inconnue : {wid}")
    return dict(row)


def list_watches(conn, active_only=True):
    sql = (
        "SELECT * FROM watches"
        + (" WHERE active = 1" if active_only else "")
        + " ORDER BY date, id"
    )
    return [dict(r) for r in conn.execute(sql)]


def remove_watch(conn, wid):
    get_watch(conn, wid)
    conn.execute("DELETE FROM watches WHERE id = ?", (wid,))
    conn.commit()


def history(conn, wid, limit=60):
    get_watch(conn, wid)
    rows = conn.execute(
        """SELECT checked_at, best_price, best_source, best_departs, n_trains, errors
           FROM checks WHERE watch_id = ? ORDER BY id DESC LIMIT ?""",
        (wid, limit),
    )
    return [dict(r) for r in reversed(rows.fetchall())]


def matches(w, j):
    """A journey the watch cares about: priced, few changes, inside the time window."""
    if j.price is None or j.changes > w["max_changes"]:
        return False
    hhmm = j.departs[11:16]
    if w["depart_after"] and hhmm < w["depart_after"]:
        return False
    return not (w["depart_before"] and hhmm > w["depart_before"])


def search(w, sources):
    """(journeys of the day, {source: error}) over the watch's sources."""
    journeys, errors = [], {}
    for name in w["sources"].split(","):
        client = sources.get(name)
        if client is None:
            errors[name] = "source désactivée"
            continue
        try:
            journeys += client.search(w["origin"], w["destination"], w["date"])
        except (
            urllib.error.URLError,
            OSError,
            ValueError,
            KeyError,
            LookupError,
            RuntimeError,
        ) as e:
            errors[name] = f"{type(e).__name__}: {e}"
    return journeys, errors


def best_of(w, journeys):
    priced = [j for j in journeys if matches(w, j)]
    return min(priced, key=lambda j: (j.price, j.departs)) if priced else None


def _eur(price):
    return f"{price:g} €"


def reasons(w, best, previous):
    """Why this price is news ([] = not). `previous` is the last check's best."""
    if best is None:
        return []
    last = w["last_alert_price"]
    if last is not None and best.price >= last:
        return []
    out = []
    if w["max_price"] is not None and best.price <= w["max_price"]:
        out.append(f"sous votre seuil de {_eur(w['max_price'])}")
    if (
        w["drop_pct"]
        and previous is not None
        and best.price <= previous * (1 - w["drop_pct"] / 100)
    ):
        out.append(
            f"-{round((1 - best.price / previous) * 100)} % depuis le dernier relevé ({_eur(previous)})"
        )
    return out


def format_alert(w, best, journeys, why, errors):
    d = date.fromisoformat(w["date"]).strftime("%d/%m")
    lines = [
        f"🚆 {w['origin']} → {w['destination']} · {d}",
        " · ".join(why).capitalize(),
    ]
    cheapest = {}
    for j in journeys:
        if matches(w, j) and (
            j.source not in cheapest or j.price < cheapest[j.source].price
        ):
            cheapest[j.source] = j
    label = {"ouigo": "OUIGO", "inoui": "TGV INOUI"}
    for name, j in sorted(cheapest.items(), key=lambda kv: kv[1].price):
        mark = " ← meilleur" if j == best else ""
        lines.append(
            f"{label.get(name, name)} {j.departs[11:16]} → {j.arrives[11:16]} : {_eur(j.price)}{mark}"
        )
    if errors:
        lines.append("Source indisponible : " + ", ".join(sorted(errors)))
    if w["note"]:
        lines.append(w["note"])
    return "\n".join(lines)


def previous_best(conn, wid):
    row = conn.execute(
        "SELECT best_price FROM checks WHERE watch_id = ? ORDER BY id DESC LIMIT 1",
        (wid,),
    ).fetchone()
    return None if row is None else row["best_price"]


def record(conn, w, journeys, best, errors, now):
    cur = conn.execute(
        """INSERT INTO checks (watch_id, checked_at, best_price, best_source, best_departs, n_trains, errors)
           VALUES (?,?,?,?,?,?,?)""",
        (
            w["id"],
            now.isoformat(timespec="seconds"),
            best and best.price,
            best and best.source,
            best and best.departs,
            len(journeys),
            "; ".join(f"{k}: {v}" for k, v in sorted(errors.items())),
        ),
    )
    conn.executemany(
        "INSERT INTO observations VALUES (?,?,?,?,?,?,?)",
        [
            (cur.lastrowid, j.source, j.departs, j.arrives, j.price, j.changes, j.train)
            for j in journeys
        ],
    )


def check(conn, w, sources, now):
    """Re-price one watch. -> (alert text or "", errors)."""
    journeys, errors = search(w, sources)
    best = best_of(w, journeys)
    prev = previous_best(conn, w["id"])
    why = reasons(w, best, prev)
    record(conn, w, journeys, best, errors, now)

    # A price back above the last alert (or no price) re-arms the watch.
    last = w["last_alert_price"]
    if why:
        last = best.price
    elif best is None or (last is not None and best.price > last):
        last = None
    conn.execute(
        "UPDATE watches SET last_alert_price = ? WHERE id = ?", (last, w["id"])
    )
    conn.commit()
    return (format_alert(w, best, journeys, why, errors) if why else ""), errors


def run(cfg, sources=None, now=None):
    """Messages to print. Raises RuntimeError when every source failed everywhere."""
    now = now or datetime.now()
    sources = src.make_sources() if sources is None else sources
    conn = connect(cfg)
    try:
        conn.execute(
            "UPDATE watches SET active = 0 WHERE active = 1 AND date < ?",
            (now.date().isoformat(),),
        )
        conn.commit()
        watches = list_watches(conn)
        messages, failed = [], 0
        for w in watches:
            text, errors = check(conn, w, sources, now)
            if len(errors) >= len(w["sources"].split(",")):
                failed += 1
            if text:
                messages.append(text)
            log(
                f"{w['id']}: {'alert' if text else 'quiet'}"
                + (f" errors={errors}" if errors else "")
            )
    finally:
        conn.close()
    if watches and failed == len(watches):
        raise RuntimeError("toutes les sources ont échoué pour toutes les watches")
    return "\n\n".join(messages)


def _parser():
    p = argparse.ArgumentParser(prog="hermes-train-watch", description=__doc__)
    sub = p.add_subparsers(dest="cmd")
    a = sub.add_parser("add", help="create or update a watch")
    a.add_argument("origin")
    a.add_argument("destination")
    a.add_argument("date", help="YYYY-MM-DD")
    a.add_argument("--max-price", type=float, help="EUR, alert at or under")
    a.add_argument(
        "--drop-pct", type=float, help="alert on a fall of this many percent"
    )
    a.add_argument("--after", dest="depart_after", help="HH:MM")
    a.add_argument("--before", dest="depart_before", help="HH:MM")
    a.add_argument("--max-changes", type=int, default=0)
    a.add_argument("--sources", help="comma list: " + ", ".join(src.SOURCES))
    a.add_argument("--note", default="")
    ls = sub.add_parser("list", help="watches with their last price")
    ls.add_argument("--all", action="store_true", help="include expired watches")
    rm = sub.add_parser("remove", help="delete a watch and its history")
    rm.add_argument("id")
    h = sub.add_parser("history", help="best price per check")
    h.add_argument("id")
    h.add_argument("--limit", type=int, default=60)
    return p


def manage(args, cfg):
    """One subcommand -> JSON-able result. ValueError/KeyError = bad input."""
    conn = connect(cfg)
    try:
        if args.cmd == "add":
            return add_watch(
                conn,
                args.origin,
                args.destination,
                args.date,
                max_price=args.max_price,
                drop_pct=args.drop_pct,
                depart_after=args.depart_after,
                depart_before=args.depart_before,
                max_changes=args.max_changes,
                sources=args.sources.split(",") if args.sources else None,
                note=args.note,
            )
        if args.cmd == "list":
            rows = list_watches(conn, active_only=not args.all)
            return [
                {**r, "last_check": (history(conn, r["id"], 1) or [None])[0]}
                for r in rows
            ]
        if args.cmd == "remove":
            remove_watch(conn, args.id)
            return {"removed": args.id}
        return history(conn, args.id, args.limit)
    finally:
        conn.close()


def main(argv=None, env=None):
    args = _parser().parse_args(argv)
    cfg = Config.from_env(env)
    if args.cmd:
        try:
            print(json.dumps(manage(args, cfg), ensure_ascii=False))
        except (ValueError, KeyError) as e:
            print(f"error: {e.args[0]}", file=sys.stderr)
            return 2
        return 0
    try:
        message = run(cfg, src.make_sources(env))
    except (RuntimeError, sqlite3.Error, OSError) as e:
        log(f"FATAL: {e}")
        return 1
    if message:
        print(message)
    return 0


if __name__ == "__main__":
    sys.exit(main())
