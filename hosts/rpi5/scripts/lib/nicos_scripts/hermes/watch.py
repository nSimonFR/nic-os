#!/usr/bin/env python3
"""
hermes-watch: follow Hermes' Telegram conversations live, read-only.

    hermes-watch            # DM + group, interleaved
    hermes-watch dm         # or: group
    hermes-watch -n 50 --tools

Tails state.db's `messages` table. A group chat is one session PER SENDER, so
"group" merges them. Sessions are re-resolved every poll: /new or a compression
rotation starts a new session under the same session_key.

Env: HERMES_HOME.
"""

import argparse
import json
import os
import sqlite3
import sys
import time
from dataclasses import dataclass
from datetime import datetime

from ..secrets import env_str

DEFAULT_HOME = "~/.hermes"
CHAT_TYPES = {"dm": ("dm",), "group": ("group", "supergroup")}


@dataclass(frozen=True)
class Config:
    hermes_home: str = DEFAULT_HOME
    which: str = "all"
    backlog: int = 20
    tools: bool = False
    interval: float = 1.0
    once: bool = False
    color: bool = False

    @classmethod
    def from_env(cls, env=None, **kw):
        home = os.path.expanduser(env_str("HERMES_HOME", DEFAULT_HOME, env))
        return cls(hermes_home=home, **kw)


def connect(path):
    # mode=ro: never takes a write lock against the gateway.
    return sqlite3.connect(f"file:{path}?mode=ro", uri=True, timeout=5)


def current_sessions(db, which):
    """{session_id: (chat, sender)} — the newest open telegram session per session_key."""
    types = CHAT_TYPES.get(which, CHAT_TYPES["dm"] + CHAT_TYPES["group"])
    rows = db.execute(
        f"""SELECT id, session_key, chat_type, origin_json FROM sessions
            WHERE source = 'telegram' AND ended_at IS NULL AND archived = 0
              AND chat_type IN ({",".join("?" * len(types))})
            ORDER BY started_at""",
        types,
    ).fetchall()
    newest = {}
    for sid, key, chat_type, origin in rows:
        newest[key] = (sid, chat_type, origin)
    out = {}
    for sid, chat_type, origin in newest.values():
        try:
            o = json.loads(origin or "{}")
        except ValueError:
            o = {}
        out[sid] = ("DM" if chat_type == "dm" else "group", o.get("user_name") or "?")
    return out


def fetch(db, sids, after_id=None, backlog=20):
    marks = ",".join("?" * len(sids))
    cols = "id, session_id, role, content, tool_calls, tool_name, timestamp, display_kind"
    if after_id is None:
        rows = db.execute(
            f"SELECT {cols} FROM messages WHERE session_id IN ({marks})"
            " ORDER BY id DESC LIMIT ?",
            (*sids, backlog),
        ).fetchall()
        return rows[::-1]
    return db.execute(
        f"SELECT {cols} FROM messages WHERE session_id IN ({marks}) AND id > ? ORDER BY id",
        (*sids, after_id),
    ).fetchall()


def _paint(text, code, color):
    return f"\033[{code}m{text}\033[0m" if color else text


def _clip(text, n=160):
    text = " ".join((text or "").split())
    return text if len(text) <= n else text[: n - 1] + "…"


def render(row, session, cfg):
    """Lines for one message row; [] when it is not worth showing."""
    _id, _sid, role, content, tool_calls, tool_name, ts, kind = row
    if role == "session_meta" or kind == "hidden":
        return []
    chat, label = session
    stamp = datetime.fromtimestamp(ts).strftime("%m-%d %H:%M")
    if cfg.which == "all":
        stamp += f" [{chat}]"
    stamp = _paint(stamp, "2", cfg.color)
    out = []
    if role == "user":
        out.append(f"{stamp} {_paint(label, '1;36', cfg.color)} ▸ {(content or '').strip()}")
    elif role == "assistant":
        if (content or "").strip():
            out.append(f"{stamp} {_paint('Hermes', '1;35', cfg.color)} ▸ {content.strip()}")
        try:
            calls = json.loads(tool_calls or "[]")
        except ValueError:
            calls = []
        for call in calls:
            fn = call.get("function") or {}
            args = _clip(fn.get("arguments") or "", 100)
            out.append(_paint(f"{stamp}   ⚙ {fn.get('name', '?')} {args}", "33", cfg.color))
    elif role == "tool" and cfg.tools:
        out.append(_paint(f"{stamp}   ↳ {tool_name or 'tool'}: {_clip(content)}", "2", cfg.color))
    return out


def run(cfg, db, out=print, sleep=time.sleep):
    sessions = current_sessions(db, cfg.which)
    if not sessions:
        out(f"no open telegram session for '{cfg.which}'")
        return 1
    out(_paint("watching: " + ", ".join(f"{c}·{u} ({k})" for k, (c, u) in sessions.items()), "2", cfg.color))
    last = 0
    for row in fetch(db, list(sessions), backlog=cfg.backlog):
        last = row[0]
        for line in render(row, sessions[row[1]], cfg):
            out(line)
    while not cfg.once:
        sleep(cfg.interval)
        fresh = current_sessions(db, cfg.which)
        for sid in fresh.keys() - sessions.keys():
            out(_paint(f"── now following {'·'.join(fresh[sid])} ({sid})", "2", cfg.color))
        sessions = fresh or sessions
        for row in fetch(db, list(sessions), after_id=last):
            last = row[0]
            for line in render(row, sessions[row[1]], cfg):
                out(line)
    return 0


def main(argv=None, env=None):
    p = argparse.ArgumentParser(prog="hermes-watch", description=__doc__.split("\n\n")[0])
    p.add_argument("which", nargs="?", default="all", choices=["all", "dm", "group"])
    p.add_argument("-n", "--backlog", type=int, default=20, help="rows of history first")
    p.add_argument("--tools", action="store_true", help="also show tool results")
    p.add_argument("--interval", type=float, default=1.0)
    p.add_argument("--once", action="store_true", help="print the backlog and exit")
    a = p.parse_args(argv)
    cfg = Config.from_env(
        env,
        which=a.which,
        backlog=a.backlog,
        tools=a.tools,
        interval=a.interval,
        once=a.once,
        color=sys.stdout.isatty(),
    )
    db = connect(os.path.join(cfg.hermes_home, "state.db"))
    try:
        return run(cfg, db, out=lambda s: print(s, flush=True))
    except KeyboardInterrupt:
        return 0
    finally:
        db.close()


if __name__ == "__main__":
    sys.exit(main())
