#!/usr/bin/env python3
"""
journal-music-fix: rewrite the music section of past journal memos.

Hand-run, as root with journal-daily's env. Every memo whose recorded text still
says "Artiste inconnu" gets its `### 🎵 Musique` section recomputed (artists now
come from spotify-artists.json, see spotify.py) and swapped in place: nothing
else in the memo is touched, and the summary is not regenerated. A memo whose
section was edited by hand is left alone.

    journal-music-fix [--apply] [YYYY-MM-DD ...]

Dry run unless --apply. With dates, only those days.
"""

import sys
import urllib.error
from datetime import date

from ..logs import logger
from ..secrets import read_secret
from ..state import load_json, save_json
from . import journal_daily as jd

TAG = "journal-music-fix"
HEADING = "### 🎵 Musique"
PLACEHOLDER = "Artiste inconnu"


def music_section(music):
    head, lines = music
    return "\n".join([f"{HEADING} - {head}", "", *lines])


def find_section(text):
    """The music section of `text` as it stands, or None. It ends at the blank
    line before the next heading or the closing rule."""
    start = text.find(HEADING)
    if start < 0:
        return None
    body = text.find("\n\n", start) + 2
    end = len(text)
    for stop in ("\n\n### ", "\n\n___"):
        at = text.find(stop, body)
        if at >= 0:
            end = min(end, at)
    return text[start:end]


def main(argv=None, env=None, run=None, opener=None, log=None):
    log = log or logger(TAG)
    argv = list(sys.argv[1:] if argv is None else argv)
    apply = "--apply" in argv
    only = {a for a in argv if not a.startswith("--")}
    cfg = jd.Config.from_env(env)
    if not cfg.state_path:
        log("FATAL: JOURNAL_STATE is not set")
        return 1
    if run is None:
        import subprocess

        def run(cmd):
            return subprocess.run(
                cmd, capture_output=True, text=True, check=True
            ).stdout

    state = load_json(cfg.state_path, {})
    memos = jd.Memos(cfg.memos_url, read_secret(cfg.token_file), opener)
    fixed = left = pending = 0
    for key in sorted(state):
        entry = state[key]
        text = entry.get("text") if isinstance(entry, dict) else None
        if not text or PLACEHOLDER not in text or (only and key not in only):
            continue
        try:
            day = date.fromisoformat(key)
        except ValueError:
            continue
        old = find_section(text)
        music = jd.day_music(cfg, run, day, log)
        if not old or not music:
            continue
        new = music_section(music)
        if new == old:
            continue
        unknown = new.count(PLACEHOLDER)
        log(f"{key}: {old.count(PLACEHOLDER)} unknown artist line(s) -> {unknown}")
        pending += 1
        if not apply:
            continue
        new_text = text.replace(old, new, 1)
        try:
            memo = memos.call("GET", f"/{entry['memo']}")
            current = memo.get("content", "")
            if text in current:
                patched = current.replace(text, new_text, 1)
            elif old in current:
                patched = current.replace(old, new, 1)
            else:
                log(f"{key}: {entry['memo']} was edited by hand; left alone")
                left += 1
                continue
            memos.call(
                "PATCH", f"/{entry['memo']}?updateMask=content", {"content": patched}
            )
        except urllib.error.HTTPError as e:
            log(f"{key}: {entry['memo']} not updated ({e.code})")
            left += 1
            continue
        entry["text"] = new_text
        save_json(cfg.state_path, state)
        fixed += 1
    log(
        f"done: {fixed} rewritten, {left} left alone"
        if apply
        else f"dry run: {pending} memos would change"
    )
    return 0


if __name__ == "__main__":
    sys.exit(main())
