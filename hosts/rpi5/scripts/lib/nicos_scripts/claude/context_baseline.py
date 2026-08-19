#!/usr/bin/env python3
"""claude-context-baseline — alert when new sessions start with too much context.

## What it measures

A session's *baseline* is what the very first request costs before any work has
happened: system prompt + CLAUDE.md + tool/MCP schemas + skills listing. It is
the sum of the three input counters on the FIRST assistant message that carries
a `usage` block in the transcript:

    input_tokens + cache_creation_input_tokens + cache_read_input_tokens

Nothing else in the transcript is a substitute. `preTokens` on a
`compact_boundary` measures the *end* of a window, not the start, and it only
exists once the session has already been damaged.

## Why it needs an alarm

On 2026-08-17 MCP schemas stopped being deferred behind ToolSearch, server-side,
on an unchanged client (2.1.220 on both sides of the boundary). Bridge sessions
went from a ~50k baseline to ~134k against a 200k window: ~33k of room, four to
six tool calls before an auto-compact that itself costs 2-4 minutes. Nothing in
this repo changed, nothing failed, and no unit went red — the only symptom was
sessions that compacted constantly. It took a transcript-archaeology session to
find. This oneshot makes the same regression page within the hour.

It is *not* redundant with the `deniedMcpServers` fix in `.claude/settings.json`:
that fix pins the four connectors known to be expensive, under both name forms.
A new connector, a new plugin, a bigger CLAUDE.md, or another upstream deferral
change all move the baseline without touching that file.

## Channel

The self-updating alerter (`shared/notify.nix` `alert`), not the one-shot sender
and not the agent aggregator — this is a condition that fires and later CLEARS
(deny the connector, the next session's baseline drops, the alert resolves
itself on the following empty body). Same seam as monitoring.nix and
anthropic-account-healthcheck.

Config via environment:
  CTXB_PROJECTS_DIR    transcript root       (default $HOME/.claude/projects)
  CTXB_THRESHOLD       page at/above, tokens (default 100000)
  CTXB_LOOKBACK        only sessions touched in the last N seconds (default 5400)
  CTXB_MAX_LINES       sessions listed in the alert body     (default 8)
  CTXB_ALERT           path to the `alert` script; unset -> journal only
  CTXB_ALERT_KEY       alerter state key      (default claude-context-baseline)
  CTXB_ALERT_TITLE     alert title
  CTXB_DRY_RUN         "0" to actually send   (default dry run)
"""

import json
import subprocess
import sys
import time
from dataclasses import dataclass
from pathlib import Path

from ..logs import logger
from ..secrets import env_int, env_str

DEFAULT_THRESHOLD = 100_000
# One timer period (1h) plus slack, so a run that starts late still sees every
# session the previous run could have missed. Overlap is harmless: the alerter
# is keyed and edits in place, so re-reporting the same session is a no-op.
DEFAULT_LOOKBACK = 5400
DEFAULT_ALERT_KEY = "claude-context-baseline"
DEFAULT_ALERT_TITLE = "🔴 Claude session baseline context too high"

log = logger("claude-context-baseline")


@dataclass(frozen=True)
class Config:
    projects_dir: Path = None
    threshold: int = DEFAULT_THRESHOLD
    lookback: int = DEFAULT_LOOKBACK
    max_lines: int = 8
    alert_cmd: str = ""
    alert_key: str = DEFAULT_ALERT_KEY
    alert_title: str = DEFAULT_ALERT_TITLE
    # Sending is the only side effect, so it is what defaults to off. A Config
    # built from an empty environment can read transcripts and log, nothing more.
    dry_run: bool = True

    @classmethod
    def from_env(cls, env=None):
        home = env_str("HOME", "/home/nsimon", env) or "/home/nsimon"
        return cls(
            projects_dir=Path(
                env_str("CTXB_PROJECTS_DIR", "", env) or f"{home}/.claude/projects"
            ),
            threshold=env_int("CTXB_THRESHOLD", DEFAULT_THRESHOLD, env),
            lookback=env_int("CTXB_LOOKBACK", DEFAULT_LOOKBACK, env),
            max_lines=env_int("CTXB_MAX_LINES", 8, env),
            alert_cmd=env_str("CTXB_ALERT", "", env),
            alert_key=env_str("CTXB_ALERT_KEY", DEFAULT_ALERT_KEY, env),
            alert_title=env_str("CTXB_ALERT_TITLE", DEFAULT_ALERT_TITLE, env),
            dry_run=env_str("CTXB_DRY_RUN", "1", env) != "0",
        )


def baseline_of(path, reader=open):
    """Baseline input tokens for one transcript, or None if it has no request yet.

    Stops at the first assistant message with a `usage` block, so this reads a
    few KB of a file that is routinely megabytes. A malformed line is skipped
    rather than fatal: transcripts are appended to live, so the last line of a
    file being written is regularly half-flushed JSON.
    """
    try:
        with reader(path) as fh:
            for line in fh:
                try:
                    msg = json.loads(line)
                except ValueError:
                    continue
                if msg.get("type") != "assistant":
                    continue
                usage = (msg.get("message") or {}).get("usage") or {}
                if not usage:
                    continue
                return (
                    usage.get("input_tokens", 0)
                    + usage.get("cache_creation_input_tokens", 0)
                    + usage.get("cache_read_input_tokens", 0)
                )
    except OSError:
        return None
    return None


def label_of(path, projects_dir):
    """`<project-dir>/<8 chars of session uuid>` — enough to find it in the app."""
    try:
        project = Path(path).parent.relative_to(projects_dir).as_posix()
    except ValueError:
        project = Path(path).parent.name
    return f"{project}/{Path(path).stem[:8]}"


def scan(cfg, now=None, lister=None, mtime=None, reader=open):
    """-> [(baseline, label, path)] for recent sessions, worst baseline first.

    `lister`/`mtime` are the filesystem seams: tests hand in a plain dict of
    path -> (mtime, text) instead of building a transcript tree on disk.
    """
    now = time.time() if now is None else now
    paths = sorted(
        (lister or (lambda: cfg.projects_dir.glob("*/*.jsonl")))()
    )
    stat = mtime or (lambda p: Path(p).stat().st_mtime)
    rows = []
    for path in paths:
        try:
            if now - stat(path) > cfg.lookback:
                continue
        except OSError:
            continue
        base = baseline_of(path, reader=reader)
        if base is None:
            continue
        rows.append((base, label_of(path, cfg.projects_dir), path))
    rows.sort(key=lambda r: -r[0])
    return rows


def build_body(cfg, rows):
    """The alerter's stdin. EMPTY means resolved — that is the whole contract."""
    over = [r for r in rows if r[0] >= cfg.threshold]
    if not over:
        return ""
    lines = [
        f"{len(over)} session(s) started above {cfg.threshold:,} tokens of "
        f"baseline context in the last {cfg.lookback // 60} min:"
    ]
    for base, label, _ in over[: cfg.max_lines]:
        lines.append(f"• {base:,} — {label}")
    if len(over) > cfg.max_lines:
        lines.append(f"… +{len(over) - cfg.max_lines} more")
    lines.append(
        "Usually a connector/plugin loading its schemas into every session. "
        "Check `mcp_instructions_delta.addedNames` in a fresh transcript and "
        "deny the culprit under BOTH name forms in .claude/settings.json."
    )
    return "\n".join(lines)


def send_alert(cfg, body, run=None, log=log):
    """Pipe `body` to the keyed alerter. Empty body clears an open alert.

    Returns True when the alerter was actually invoked. Unset CTXB_ALERT (running
    this by hand) or a dry run -> no-op, which is why an all-defaults Config is
    safe.
    """
    if not cfg.alert_cmd:
        return False
    if cfg.dry_run:
        log(f"DRY RUN — would {'open' if body else 'clear'} alert {cfg.alert_key!r}")
        return False
    try:
        (run or subprocess.run)(
            [cfg.alert_cmd, cfg.alert_key, cfg.alert_title],
            input=body.encode(),
            stdout=subprocess.DEVNULL,
            timeout=30,
            check=False,
        )
        return True
    except Exception as e:  # noqa: BLE001 — best effort, never fail the timer
        log(f"alert failed: {e}")
        return False


def main(env=None, now=None, lister=None, mtime=None, reader=open, run=None, log=log):
    cfg = Config.from_env(env)
    rows = scan(cfg, now=now, lister=lister, mtime=mtime, reader=reader)
    if not rows:
        # No session started in the window. Deliberately NOT a resolve: a quiet
        # night must not clear a real alert that nothing has disproved yet.
        log(f"no sessions in the last {cfg.lookback}s — nothing to judge")
        return 0
    worst, worst_label, _ = rows[0]
    body = build_body(cfg, rows)
    verdict = "ALERT" if body else "OK"
    log(
        f"{verdict} {len(rows)} session(s), worst {worst:,} ({worst_label}), "
        f"threshold {cfg.threshold:,}"
    )
    send_alert(cfg, body, run=run, log=log)
    return 0


if __name__ == "__main__":
    sys.exit(main())
