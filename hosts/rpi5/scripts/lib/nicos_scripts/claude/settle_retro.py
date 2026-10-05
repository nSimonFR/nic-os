#!/usr/bin/env python3
"""t3-settle-retro — run mattpocock's /retro on each T3 Code thread you settle.

T3 Code (0.0.46) has no on-settle hook, so this polls its state DB, read-only.
A settled Claude thread is reviewed by forking its session — never persisted, so
the original thread is untouched — in plan mode with read-only tools. Findings
land in RETRO_DIR as markdown and are never pushed: nic-os is public, and a retro
quotes the session it reviews.

A thread is reviewed again only when it is re-settled with more turns. The first
run records what is already settled without reviewing it.

Config via environment:
  RETRO_T3_DB        T3 state DB              (default ~/.t3/userdata/statev2.sqlite)
  RETRO_DIR          output dir               (default ~/retros)
  RETRO_STATE        reviewed-thread ledger   (default $RETRO_DIR/.state.json)
  RETRO_CLAUDE       claude binary            (default claude)
  RETRO_MODEL        model                    (default sonnet)
  RETRO_MIN_TURNS    skip shorter threads     (default 3)
  RETRO_MAX_PER_RUN  reviews per run          (default 2)
  RETRO_TIMEOUT      seconds per review       (default 1800)
  RETRO_DRY_RUN      "0" to actually review   (default dry run)
"""

import json
import os
import re
import sqlite3
import subprocess
import sys
from dataclasses import dataclass
from pathlib import Path

from ..logs import logger
from ..secrets import env_int, env_str
from ..state import ensure_dir, load_json, save_json

log = logger("t3-settle-retro")

PROMPT = (
    "/mattpocock-skills:retro this session, up to the message before this one. "
    "Your reply is saved verbatim to a markdown file: start straight at the first "
    "candidate, no preamble. This run is read-only — suggest, never apply."
)

QUERY = """
SELECT t.thread_id, t.title, t.payload_json, pr.title,
       pt.payload_json, ps.payload_json,
       (SELECT count(*) FROM orchestration_v2_projection_runs r WHERE r.thread_id = t.thread_id)
FROM orchestration_v2_projection_threads t
JOIN orchestration_v2_projection_provider_threads pt ON pt.provider_thread_id = (
  SELECT provider_thread_id FROM orchestration_v2_projection_provider_threads
  WHERE thread_id = t.thread_id AND provider = 'claudeAgent'
  ORDER BY updated_at DESC LIMIT 1)
LEFT JOIN orchestration_v2_projection_provider_sessions ps ON ps.provider_session_id = pt.provider_session_id
LEFT JOIN projection_projects pr ON pr.project_id = t.project_id
WHERE t.deleted_at IS NULL AND json_extract(t.payload_json, '$.settledAt') IS NOT NULL
ORDER BY json_extract(t.payload_json, '$.settledAt')
"""


@dataclass(frozen=True)
class Config:
    db: Path
    out_dir: Path
    state_file: Path
    claude: str = "claude"
    model: str = "sonnet"
    min_turns: int = 3
    max_per_run: int = 2
    timeout: int = 1800
    dry_run: bool = True

    @classmethod
    def from_env(cls, env=None):
        home = Path(env_str("HOME", "", env) or Path.home())
        out_dir = Path(env_str("RETRO_DIR", "", env) or home / "retros")
        return cls(
            db=Path(env_str("RETRO_T3_DB", "", env) or home / ".t3/userdata/statev2.sqlite"),
            out_dir=out_dir,
            state_file=Path(env_str("RETRO_STATE", "", env) or out_dir / ".state.json"),
            claude=env_str("RETRO_CLAUDE", "", env) or "claude",
            model=env_str("RETRO_MODEL", "", env) or "sonnet",
            min_turns=env_int("RETRO_MIN_TURNS", 3, env),
            max_per_run=env_int("RETRO_MAX_PER_RUN", 2, env),
            timeout=env_int("RETRO_TIMEOUT", 1800, env),
            dry_run=env_str("RETRO_DRY_RUN", "1", env) != "0",
        )


@dataclass(frozen=True)
class Thread:
    thread_id: str
    title: str
    branch: str
    cwd: str
    settled_at: str
    project: str
    session_id: str
    turns: int


def settled_threads(db, connect=sqlite3.connect):
    """Settled Claude threads, oldest settle first. Read-only: T3 owns the DB."""
    con = connect(f"file:{db}?mode=ro", uri=True)
    try:
        rows = con.execute(QUERY).fetchall()
    finally:
        con.close()
    out = []
    for tid, title, thread_json, project, pt_json, ps_json, runs in rows:
        try:
            thread, pt, ps = (json.loads(j or "{}") for j in (thread_json, pt_json, ps_json))
        except ValueError:
            continue
        session = (pt.get("nativeThreadRef") or {}).get("nativeId")
        if not session:
            continue
        out.append(Thread(
            thread_id=tid, title=title or "", branch=thread.get("branch") or "",
            # The fork must run where the session lives: Claude Code finds it by cwd.
            cwd=ps.get("cwd") or thread.get("worktreePath") or "",
            settled_at=thread["settledAt"], project=project or "",
            session_id=session, turns=int(runs or 0),
        ))
    return out


def due(threads, ledger, min_turns):
    """Threads to review now: new, or re-settled after more turns."""
    return [
        t for t in threads
        if t.turns >= min_turns and t.turns > ledger.get(t.thread_id, {}).get("turns", 0)
    ]


def slug(text, limit=40):
    s = re.sub(r"[^a-z0-9]+", "-", text.lower()).strip("-")
    return s[:limit].rstrip("-") or "thread"


def out_path(cfg, t):
    return cfg.out_dir / f"{t.settled_at[:10]}-{slug(t.project, 20)}-{slug(t.title)}-{t.thread_id[:8]}.md"


def argv(cfg, t):
    return [
        cfg.claude, "-p",
        "--resume", t.session_id, "--fork-session", "--no-session-persistence",
        "--model", cfg.model,
        "--permission-mode", "plan",
        "--tools", "Read,Grep,Glob,Skill",
        "--output-format", "json",
    ]


def render(t, cfg, result):
    cost = result.get("total_cost_usd")
    head = [
        f"# Retro — {t.title}",
        "",
        f"- project **{t.project}** · branch `{t.branch}` · settled {t.settled_at[:16].replace('T', ' ')}",
        f"- thread `{t.thread_id}` · session `{t.session_id}` · {t.turns} turns",
        f"- {cfg.model}" + (f" · ${cost:.2f}" if isinstance(cost, (int, float)) else ""),
        "",
    ]
    return "\n".join(head) + "\n" + (result.get("result") or "").strip() + "\n"


def review(cfg, t, run=None, isdir=os.path.isdir, log=log):
    """-> the markdown, or None on failure."""
    if not isdir(t.cwd):
        log(f"{t.thread_id}: cwd {t.cwd!r} is gone, cannot resume")
        return None
    try:
        res = (run or subprocess.run)(
            argv(cfg, t), input=PROMPT, cwd=t.cwd,
            capture_output=True, text=True, timeout=cfg.timeout,
        )
    except Exception as e:  # noqa: BLE001
        log(f"{t.thread_id}: claude failed: {e}")
        return None
    try:
        result = json.loads(res.stdout)
    except ValueError:
        result = {}
    if res.returncode != 0 or result.get("is_error") or not result.get("result"):
        log(f"{t.thread_id}: claude exited {res.returncode}: {(res.stdout + res.stderr).strip()[:300]}")
        return None
    return render(t, cfg, result)


def main(env=None, connect=sqlite3.connect, run=None, isdir=os.path.isdir, log=log):
    cfg = Config.from_env(env)
    threads = settled_threads(cfg.db, connect=connect)

    if not cfg.state_file.exists():
        ledger = {t.thread_id: {"turns": t.turns, "seeded": True} for t in threads}
        log(f"first run: recorded {len(ledger)} already-settled thread(s) without reviewing")
        if not cfg.dry_run:
            ensure_dir(str(cfg.out_dir))
            save_json(str(cfg.state_file), ledger, indent=2, sort_keys=True)
        return 0

    ledger = load_json(str(cfg.state_file), {})
    todo = due(threads, ledger, cfg.min_turns)
    if not todo:
        return 0
    log(f"{len(todo)} thread(s) to review, {min(len(todo), cfg.max_per_run)} this run")

    failed = 0
    for t in todo[: cfg.max_per_run]:
        path = out_path(cfg, t)
        if cfg.dry_run:
            log(f"DRY RUN — would review {t.title!r} into {path}: {' '.join(argv(cfg, t))}")
            continue
        md = review(cfg, t, run=run, isdir=isdir, log=log)
        # Recorded either way: a failed review must not be retried, and paid for, every tick.
        ledger[t.thread_id] = {"turns": t.turns, "ok": md is not None}
        if md is None:
            failed += 1
        else:
            ensure_dir(str(cfg.out_dir))
            path.write_text(md)
            log(f"{t.title!r} -> {path}")
        save_json(str(cfg.state_file), ledger, indent=2, sort_keys=True)
    return 1 if failed else 0


if __name__ == "__main__":
    sys.exit(main())
