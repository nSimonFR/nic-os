#!/usr/bin/env python3
"""
hermes-zen-watch: has Zen Browser shipped desktop space/container sync yet?

Replaces the weekly LLM "veille" job. That job read a handoff note in /tmp,
searched the web, and reported in French — but its actual question was binary and
checkable against a primary source: *does `ZenSyncManager.sys.mjs` exist in the
zen-browser/desktop tree at the latest release tag?* Two unauthenticated GitHub
API calls answer it, so no model and no web search are needed.

(The old job also opened by reading /tmp/zen-arc-handoff/HANDOFF.md. That path is
gone — /tmp is cleared — so every recent run began by silently failing its first
instruction. The watched-paths list below is the durable form of what that note
was tracking.)

**Silence is the steady state.** Empty stdout is a silent run for Hermes, so this
prints only when a watched path appears or disappears. A weekly "nothing changed"
message is noise; the release tag alone changes most weeks and says nothing about
sync. Set ZEN_ALWAYS_REPORT=1 to get the old always-speak behaviour.

Config (all from the environment, read once in main()):

  ZEN_REPO           default zen-browser/desktop
  ZEN_STATE_FILE     default $HOME/.hermes/workspace/zen-watch/state.json
  ZEN_WATCH_PATHS    colon-separated repo paths to watch (default: the sync trio)
  ZEN_ALWAYS_REPORT  "1" to print an "aucun changement" line instead of staying silent
  GITHUB_TOKEN       optional; only raises the 60/hr anonymous rate limit
"""

import os
import sys
import urllib.error
from dataclasses import dataclass
from pathlib import Path

from ..httpjson import get_json
from ..logs import logger
from ..secrets import env_str
from ..state import ensure_dir, load_json, save_json

# stderr, NOT the default stdout: stdout is the delivered message.
log = logger("hermes-zen-watch", lambda: sys.stderr)

API = "https://api.github.com"

# The desktop-sync surface the handoff note was waiting on. ZenSyncManager is the
# one the question named; the other two are the workspace/window halves that make
# it actually usable, and they land separately.
DEFAULT_WATCH_PATHS = (
    "src/zen/sync/ZenSyncManager.sys.mjs",
    "src/zen/sync/ZenWorkspacesSync.sys.mjs",
    "src/zen/sessionstore/ZenWindowSync.sys.mjs",
)

DEFAULT_STATE = "~/.hermes/workspace/zen-watch/state.json"


@dataclass(frozen=True)
class Config:
    repo: str = "zen-browser/desktop"
    state_file: str = DEFAULT_STATE
    watch_paths: tuple = DEFAULT_WATCH_PATHS
    always_report: bool = False
    token: str = ""

    @classmethod
    def from_env(cls, env=None):
        raw = env_str("ZEN_WATCH_PATHS", "", env).strip()
        paths = tuple(p for p in raw.split(":") if p) if raw else DEFAULT_WATCH_PATHS
        return cls(
            repo=env_str("ZEN_REPO", "zen-browser/desktop", env),
            state_file=os.path.expanduser(
                env_str("ZEN_STATE_FILE", DEFAULT_STATE, env)
            ),
            watch_paths=paths,
            always_report=env_str("ZEN_ALWAYS_REPORT", "", env).strip() == "1",
            token=env_str("GITHUB_TOKEN", "", env),
        )


def _headers(cfg):
    headers = {
        "Accept": "application/vnd.github+json",
        "User-Agent": "nic-os-zen-watch",
    }
    if cfg.token:
        headers["Authorization"] = f"Bearer {cfg.token}"
    return headers


def latest_release(cfg, opener=None):
    """Tag, name and date of the newest published release."""
    data = get_json(
        f"{API}/repos/{cfg.repo}/releases/latest", _headers(cfg), opener=opener
    )
    return {
        "tag": data.get("tag_name") or "",
        "name": data.get("name") or "",
        "published": (data.get("published_at") or "")[:10],
        "url": data.get("html_url") or "",
    }


def tree_paths(cfg, ref, opener=None):
    """Every path in the repo at `ref`.

    One recursive tree call (~2.3k entries, well under the truncation limit) is
    both cheaper and more reliable than the code-search API, which returns 0 hits
    for this repo even for paths that demonstrably exist.
    """
    data = get_json(
        f"{API}/repos/{cfg.repo}/git/trees/{ref}?recursive=1",
        _headers(cfg),
        opener=opener,
    )
    if data.get("truncated"):
        log("WARNING: tree response truncated — presence checks may be wrong")
    return {entry.get("path") for entry in data.get("tree") or []}


def first_commit(cfg, path, opener=None):
    """When `path` was introduced, for context in the report. Best-effort."""
    try:
        commits = get_json(
            f"{API}/repos/{cfg.repo}/commits?path={path}&per_page=100",
            _headers(cfg),
            opener=opener,
        )
    except (urllib.error.URLError, OSError, ValueError):
        return None
    if not isinstance(commits, list) or not commits:
        return None
    oldest = commits[-1]
    commit = oldest.get("commit") or {}
    return {
        "date": ((commit.get("author") or {}).get("date") or "")[:10],
        "message": (commit.get("message") or "").split("\n")[0],
    }


def diff_presence(previous, current):
    """Paths that flipped, as (path, now_present) pairs, in a stable order."""
    changes = []
    for path in sorted(set(previous) | set(current)):
        was, now = bool(previous.get(path)), bool(current.get(path))
        if was != now:
            changes.append((path, now))
    return changes


def build_report(cfg, release, changes, context):
    """French, plain text — the one thing this job delivers when it speaks."""
    lines = ["🔎 Zen Browser · veille sync"]
    tag = release.get("tag") or "?"
    published = release.get("published") or "?"
    lines.append(f"Version : {tag} ({published})")
    lines.append("")

    appeared = [p for p, now in changes if now]
    vanished = [p for p, now in changes if not now]

    if appeared:
        lines.append("Nouveau dans l'arbre source :")
        for path in appeared:
            lines.append(f"• {path}")
            info = context.get(path)
            if info and info.get("date"):
                lines.append(f"  arrivé le {info['date']} — {info['message']}")
        lines.append("")
        lines.append(
            "La synchronisation desktop (espaces/conteneurs) est donc présente "
            "dans le code publié."
        )

    if vanished:
        if appeared:
            lines.append("")
        lines.append("Disparu de l'arbre source (renommage ou retrait) :")
        for path in vanished:
            lines.append(f"• {path}")

    lines.append("")
    lines.append(
        "Non vérifiable ici : le comportement réel de la sync entre profils, "
        "qui demande le Mac et un profil Zen — cet hôte n'a ni l'un ni l'autre."
    )
    if release.get("url"):
        lines.append(release["url"])
    return "\n".join(lines)


def run(cfg, opener=None):
    """Returns the message to print ("" = stay silent)."""
    release = latest_release(cfg, opener=opener)
    tag = release.get("tag")
    if not tag:
        raise RuntimeError("no tag_name on the latest release")

    paths = tree_paths(cfg, tag, opener=opener)
    current = {p: (p in paths) for p in cfg.watch_paths}

    state = load_json(cfg.state_file, {})
    previous = state.get("paths") or {}
    changes = diff_presence(previous, current)

    # First run has no baseline. Report only the paths that already exist —
    # a baseline of "these three are absent" is not news worth a message.
    if not previous:
        changes = [(p, True) for p in cfg.watch_paths if current[p]]

    context = {}
    for path, now in changes:
        if now:
            info = first_commit(cfg, path, opener=opener)
            if info:
                context[path] = info

    ensure_dir(str(Path(cfg.state_file).parent))
    save_json(
        cfg.state_file,
        {"tag": tag, "published": release.get("published"), "paths": current},
        indent=2,
        sort_keys=True,
    )

    if changes:
        return build_report(cfg, release, changes, context)
    if cfg.always_report:
        return "Zen : aucun changement matériel détecté cette semaine."
    log(f"no watched-path change at {tag} — silent")
    return ""


def main(argv=None, env=None):
    del argv
    cfg = Config.from_env(env)
    try:
        message = run(cfg)
    except (urllib.error.URLError, OSError, ValueError, RuntimeError) as e:
        log(f"FATAL: GitHub API check failed ({e})")
        return 1
    if message:
        print(message)
    return 0


if __name__ == "__main__":
    sys.exit(main())
