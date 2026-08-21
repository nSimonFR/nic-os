#!/usr/bin/env python3
"""
hermes-zen-watch: has Zen Browser shipped desktop space/container sync yet?

The weekly LLM "veille" searched the web to answer a question that is binary and
checkable against a primary source: does `ZenSyncManager.sys.mjs` exist in
zen-browser/desktop at the latest release tag? Two anonymous GitHub calls answer
it. (The old prompt also opened by reading /tmp/zen-arc-handoff/HANDOFF.md, since
cleared — so every recent run silently failed its first instruction. WATCH_PATHS
is the durable form of what that note tracked.)

Silence is the steady state: it prints only when a watched path appears or
disappears. The release tag changes most weeks and says nothing about sync, so a
weekly "nothing changed" line is noise — ZEN_ALWAYS_REPORT=1 restores it.

Env: ZEN_{REPO,STATE_FILE,WATCH_PATHS,ALWAYS_REPORT}, GITHUB_TOKEN.
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

# stderr: stdout is the delivered message.
log = logger("hermes-zen-watch", lambda: sys.stderr)

API = "https://api.github.com"

# ZenSyncManager is the file the question named; the other two are the
# workspace/window halves that make it usable, and they land separately.
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
        return cls(
            repo=env_str("ZEN_REPO", "zen-browser/desktop", env),
            state_file=os.path.expanduser(env_str("ZEN_STATE_FILE", DEFAULT_STATE, env)),
            watch_paths=tuple(p for p in raw.split(":") if p) or DEFAULT_WATCH_PATHS,
            always_report=env_str("ZEN_ALWAYS_REPORT", "", env).strip() == "1",
            token=env_str("GITHUB_TOKEN", "", env),
        )


def _headers(cfg):
    headers = {"Accept": "application/vnd.github+json", "User-Agent": "nic-os-zen-watch"}
    if cfg.token:
        headers["Authorization"] = f"Bearer {cfg.token}"
    return headers


def latest_release(cfg, opener=None):
    d = get_json(f"{API}/repos/{cfg.repo}/releases/latest", _headers(cfg), opener=opener)
    return {
        "tag": d.get("tag_name") or "",
        "published": (d.get("published_at") or "")[:10],
        "url": d.get("html_url") or "",
    }


def tree_paths(cfg, ref, opener=None):
    """Every path at `ref`. One recursive tree call (~2.3k entries, untruncated)
    beats the code-search API, which returns 0 hits for this repo even for paths
    that demonstrably exist."""
    d = get_json(
        f"{API}/repos/{cfg.repo}/git/trees/{ref}?recursive=1", _headers(cfg), opener=opener
    )
    if d.get("truncated"):
        log("WARNING: tree response truncated — presence checks may be wrong")
    return {e.get("path") for e in d.get("tree") or []}


def first_commit(cfg, path, opener=None):
    """When `path` was introduced, for context. Best-effort."""
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
    commit = commits[-1].get("commit") or {}
    return {
        "date": ((commit.get("author") or {}).get("date") or "")[:10],
        "message": (commit.get("message") or "").split("\n")[0],
    }


def diff_presence(previous, current):
    """Paths that flipped, as (path, now_present), in a stable order."""
    return [
        (p, bool(current.get(p)))
        for p in sorted(set(previous) | set(current))
        if bool(previous.get(p)) != bool(current.get(p))
    ]


def build_report(release, changes, context):
    lines = [
        "🔎 Zen Browser · veille sync",
        f"Version : {release.get('tag') or '?'} ({release.get('published') or '?'})",
        "",
    ]
    appeared = [p for p, now in changes if now]
    vanished = [p for p, now in changes if not now]

    if appeared:
        lines.append("Nouveau dans l'arbre source :")
        for path in appeared:
            lines.append(f"• {path}")
            info = context.get(path)
            if info and info.get("date"):
                lines.append(f"  arrivé le {info['date']} — {info['message']}")
        lines += [
            "",
            "La synchronisation desktop (espaces/conteneurs) est donc présente "
            "dans le code publié.",
        ]
    if vanished:
        lines += [""] if appeared else []
        lines.append("Disparu de l'arbre source (renommage ou retrait) :")
        lines += [f"• {p}" for p in vanished]

    lines += [
        "",
        "Non vérifiable ici : le comportement réel de la sync entre profils, qui "
        "demande le Mac et un profil Zen — cet hôte n'a ni l'un ni l'autre.",
    ]
    if release.get("url"):
        lines.append(release["url"])
    return "\n".join(lines)


def run(cfg, opener=None):
    """The message to print — "" means stay silent."""
    release = latest_release(cfg, opener=opener)
    if not release["tag"]:
        raise RuntimeError("no tag_name on the latest release")

    paths = tree_paths(cfg, release["tag"], opener=opener)
    current = {p: (p in paths) for p in cfg.watch_paths}
    previous = load_json(cfg.state_file, {}).get("paths") or {}

    # First run has no baseline, so report only what already exists — "these three
    # are absent" is not news.
    changes = (
        diff_presence(previous, current)
        if previous
        else [(p, True) for p in cfg.watch_paths if current[p]]
    )
    context = {
        p: info
        for p, now in changes
        if now and (info := first_commit(cfg, p, opener=opener))
    }

    ensure_dir(str(Path(cfg.state_file).parent))
    save_json(
        cfg.state_file,
        {"tag": release["tag"], "published": release["published"], "paths": current},
        indent=2,
        sort_keys=True,
    )

    if changes:
        return build_report(release, changes, context)
    if cfg.always_report:
        return "Zen : aucun changement matériel détecté cette semaine."
    log(f"no watched-path change at {release['tag']} — silent")
    return ""


def main(argv=None, env=None):
    del argv
    try:
        message = run(Config.from_env(env))
    except (urllib.error.URLError, OSError, ValueError, RuntimeError) as e:
        log(f"FATAL: GitHub API check failed ({e})")
        return 1
    if message:
        print(message)
    return 0


if __name__ == "__main__":
    sys.exit(main())
