#!/usr/bin/env python3
"""Mirror Claude Code memory files into the notes wiki (hosts/rpi5/notes.nix).

Wired as a PostToolUse hook on Write|Edit (see claude-settings.json). Reads the hook
payload from stdin:
    {"tool_name": "Write|Edit", "tool_input": {"file_path": ..., ...}, ...}

Only <PROJECTS>/<project>/memory/*.md of the one configured project is mirrored, into
<DEST>/<group>/<file>, where group comes from the filename prefix (known_issue_ ->
"Known issues", …); MEMORY.md stays at the top and its links are rewritten to the
grouped paths. `claude-memory-sync --all` re-mirrors every file (backfill).

Always exits 0; never blocks Claude Code. Errors land in ~/.claude/logs/memory-sync.log.

Config via environment (all optional — the defaults are the live paths):
  MEMORY_SYNC_PROJECTS_DIR   default ~/.claude/projects
  MEMORY_SYNC_PROJECT        default -home-nsimon-nic-os
  MEMORY_SYNC_DEST           default /mnt/data/notes/8 🧠 Wiki/Pages/Claude Memory
  MEMORY_SYNC_LOG_PATH       default ~/.claude/logs/memory-sync.log
"""

import json
import re
import sys
import time
from dataclasses import dataclass
from pathlib import Path

from ..secrets import env_str

DEFAULT_PROJECT = "-home-nsimon-nic-os"
DEFAULT_DEST = "/mnt/data/notes/8 🧠 Wiki/Pages/Claude Memory"
GROUPS = (
    (re.compile(r"^known[_-]issue", re.I), "Known issues"),
    (re.compile(r"^(project|todo)[_-]", re.I), "Projects"),
    (re.compile(r"^reference[_-]", re.I), "References"),
    (re.compile(r"^feedback[_-]", re.I), "Feedback"),
)
LINK = re.compile(r"\]\(([^)\s/]+\.md)\)")


@dataclass(frozen=True)
class Config:
    projects_dir: Path = None
    project: str = DEFAULT_PROJECT
    dest: Path = None
    log_path: Path = None

    @classmethod
    def from_env(cls, env=None, home=None):
        home = Path(home or env_str("HOME", str(Path.home()), env))

        def path_of(name, default):
            return Path(env_str(name, "", env) or default)

        return cls(
            projects_dir=path_of("MEMORY_SYNC_PROJECTS_DIR", home / ".claude/projects"),
            project=env_str("MEMORY_SYNC_PROJECT", DEFAULT_PROJECT, env),
            dest=path_of("MEMORY_SYNC_DEST", DEFAULT_DEST),
            log_path=path_of("MEMORY_SYNC_LOG_PATH", home / ".claude/logs/memory-sync.log"),
        )


def make_log(cfg):
    def log(msg):
        try:
            cfg.log_path.parent.mkdir(parents=True, exist_ok=True)
            with cfg.log_path.open("a") as f:
                f.write(f"{time.strftime('%Y-%m-%dT%H:%M:%S')} {msg}\n")
        except Exception:  # noqa: BLE001 — a hook must never fail on its own log
            pass
    return log


def memory_file(cfg, path):
    """Return the memory filename if path is <PROJECTS>/<project>/memory/<file>.md."""
    try:
        parts = Path(path).relative_to(cfg.projects_dir).parts
    except ValueError:
        return None
    if len(parts) != 3 or parts[0] != cfg.project or parts[1] != "memory" \
            or not parts[2].endswith(".md"):
        return None
    return parts[2]


def group_for(file_name):
    for pattern, group in GROUPS:
        if pattern.match(file_name):
            return group
    return None


def relpath_for(file_name):
    group = group_for(file_name)
    return f"{group}/{file_name}" if group else file_name


def rewrite_index_links(content):
    return LINK.sub(lambda m: f"]({relpath_for(m.group(1)).replace(' ', '%20')})", content)


def sync(cfg, path, file_name, log=None):
    log = log or make_log(cfg)
    content = Path(path).read_text()
    if file_name == "MEMORY.md":
        content = rewrite_index_links(content)
    target = cfg.dest / relpath_for(file_name)
    target.parent.mkdir(parents=True, exist_ok=True)
    if target.exists() and target.read_text() == content:
        return target
    tmp = target.with_name(f".{target.name}.tmp")
    tmp.write_text(content)
    tmp.replace(target)
    log(f"WRITE {target.relative_to(cfg.dest)}")
    return target


def sync_all(cfg, log=None):
    log = log or make_log(cfg)
    memory_dir = cfg.projects_dir / cfg.project / "memory"
    return [sync(cfg, p, p.name, log=log) for p in sorted(memory_dir.glob("*.md"))]


def main(env=None, stdin=None, argv=None):
    cfg = Config.from_env(env)
    log = make_log(cfg)
    argv = sys.argv[1:] if argv is None else argv
    if "--all" in argv:
        written = sync_all(cfg, log=log)
        print(f"mirrored {len(written)} memory files into {cfg.dest}")
        return 0

    try:
        payload = json.load(stdin or sys.stdin)
    except Exception as e:  # noqa: BLE001
        log(f"bad-stdin: {type(e).__name__}: {e}")
        return 0
    if payload.get("tool_name") not in ("Write", "Edit"):
        return 0
    file_path = (payload.get("tool_input") or {}).get("file_path")
    if not file_path:
        return 0

    path = Path(file_path).resolve()
    file_name = memory_file(cfg, path)
    if not file_name or not path.exists():
        return 0
    try:
        sync(cfg, path, file_name, log=log)
    except Exception as e:  # noqa: BLE001 — a hook must never block Claude Code
        log(f"FAIL {path.name}: {type(e).__name__}: {e}")
    return 0


if __name__ == "__main__":
    sys.exit(main())
