#!/usr/bin/env python3
"""Agent plan usage for herdr's ui.tab_bar_right.

Prints one line, e.g.

    claude ██▏░░░ 5:36%/W:24%/F:3% │ codex ██████ 5:0%/W:100% 🔴

and exits non-zero when nothing at all could be read, so herdr clears the entry
rather than leaving a number on screen that has stopped meaning anything.

Sources are the live ones, not the on-disk caches the other herdr usage plugins
read, both of which are wrong on this machine:

  claude  GET api.anthropic.com/api/oauth/usage with the OAuth token Claude
          Code keeps in the login Keychain — the same numbers as /status.
          ~/.claude.json has no cachedUsageUtilization key to fall back on, and
          capturing the statusLine payload instead needs a wrapper written into
          settings.json, which is a symlink into this repo.

  codex   `codex app-server` JSON-RPC account/rateLimits/read. The rollout files
          under ~/.codex/sessions are deliberately NOT used: recent sessions
          carry no rate_limits at all, so scanning them reports week-old values
          (observed: a 100%-consumed weekly window displayed as 50%).

Colour is emoji rather than ANSI because herdr strips ESC sequences from
tab-bar command output. 🟡/🔴 appear only above the thresholds, so the line
stays quiet until a window actually matters.
"""

from __future__ import annotations

import datetime
import json
import os
import subprocess
import sys
import threading
import time
import urllib.request

WARN_PCT = 60
HOT_PCT = 85

# api.anthropic.com/api/oauth/usage answers 429 when polled hard, and a 429 is
# indistinguishable on screen from "no data". So the fetch interval is decoupled
# from herdr's render interval: herdr may call this every 60s, we only go to the
# network every CLAUDE_TTL. Codex is a local process spawn, but still not worth
# doing every minute.
CACHE_PATH = os.path.expanduser("~/.cache/herdr/usage-bar.json")
CLAUDE_TTL = 900
CODEX_TTL = 180
# Past this, a cached reading is dropped rather than shown with a stale marker.
MAX_STALE = 6 * 3600
# After a failed fetch, do not try again until this has passed. The usage
# endpoint's budget is undocumented and small: a burst of one-off calls plus a
# 60s poll got it answering 429 with `retry-after: 0`, and it stayed that way
# for over fifteen minutes. Retrying every render would just extend that.
BACKOFF = 1800

def mark(pct: float) -> str:
    return " 🔴" if pct >= HOT_PCT else (" 🟡" if pct >= WARN_PCT else "")


def render(windows: list) -> str:
    """[("5", 36.0, None), ("W", 24.0, None)] -> "5:36%/W:24%"."""
    return "/".join(f"{label}:{pct:.0f}%" for label, pct, _ in windows)


def reset_at(epoch: float | None) -> str:
    """Local clock time a window reopens. Absolute, not a countdown: the bar
    re-renders on a 60s timer off a cached reading, so "in 2h" would be wrong
    for up to the whole TTL. Same day gets HH:MM, further out gets a weekday."""
    if not epoch:
        return ""
    when = datetime.datetime.fromtimestamp(float(epoch))
    fmt = "%H:%M" if when.date() == datetime.date.today() else "%a %H:%M"
    # Space after the glyph: U+21BB is East-Asian "ambiguous" width, so the
    # terminal reserves one cell and the font draws into the next one, clipping
    # the first digit.
    return f" \u21bb {when.strftime(fmt)}"


def norm(windows: list) -> list:
    """Tolerate 2-tuples cached by an older build alongside new 3-tuples."""
    return [(w[0], float(w[1]), w[2] if len(w) > 2 else None) for w in windows]


def iso_epoch(value: str | None) -> float | None:
    try:
        return datetime.datetime.fromisoformat(value).timestamp()
    except Exception:
        return None


def window_label(minutes: float | None) -> str:
    """Short label for a rate-limit window: 300min -> "5", 10080min -> "W"."""
    if not minutes:
        return "?"
    minutes = int(minutes)
    if minutes == 10080:
        return "W"
    if minutes % 10080 == 0:
        return f"{minutes // 10080}W"
    if minutes >= 1440:
        return f"{minutes // 1440}d"
    return f"{minutes // 60}"


def load_cache() -> dict:
    try:
        with open(CACHE_PATH) as f:
            return json.load(f)
    except Exception:
        return {}


def save_cache(cache: dict) -> None:
    try:
        os.makedirs(os.path.dirname(CACHE_PATH), exist_ok=True)
        tmp = f"{CACHE_PATH}.{os.getpid()}"
        with open(tmp, "w") as f:
            json.dump(cache, f)
        os.replace(tmp, CACHE_PATH)
    except Exception:
        pass


def cached(cache: dict, key: str, ttl: int, fetch) -> tuple[list | None, bool]:
    """Return (windows, stale). Refetch past ttl; fall back to the last good
    reading when the fetch fails, which is what a 429 looks like."""
    entry = cache.get(key) or {}
    now = time.time()
    age = now - entry.get("at", 0)
    if entry.get("windows") and age < ttl:
        return entry["windows"], False
    if now < entry.get("retry_at", 0):
        return (entry["windows"], True) if entry.get("windows") and age < MAX_STALE else (None, False)

    fresh = fetch()
    if fresh:
        cache[key] = {"at": now, "windows": fresh}
        return fresh, False

    entry["retry_at"] = now + BACKOFF
    cache[key] = entry
    if entry.get("windows") and age < MAX_STALE:
        return entry["windows"], True
    return None, False


def claude_token() -> str | None:
    """Claude Code's OAuth token: login Keychain on darwin, credentials file on
    Linux. Both are tried, in that order, because only one exists per host —
    there is no Keychain on rpi5, and the Mac keeps no credentials file."""
    try:
        raw = subprocess.run(
            ["security", "find-generic-password", "-s", "Claude Code-credentials", "-w"],
            capture_output=True, text=True, timeout=5,
        )
        if raw.returncode == 0:
            return json.loads(raw.stdout)["claudeAiOauth"]["accessToken"]
    except Exception:
        pass
    try:
        with open(os.path.expanduser("~/.claude/.credentials.json")) as f:
            return json.load(f)["claudeAiOauth"]["accessToken"]
    except Exception:
        return None
    return None


def claude_windows() -> list[tuple[str, float]] | None:
    token = claude_token()
    if not token:
        return None

    req = urllib.request.Request(
        "https://api.anthropic.com/api/oauth/usage",
        headers={"Authorization": f"Bearer {token}", "anthropic-beta": "oauth-2025-04-20"},
    )
    # The Aperture shim MITMs api.anthropic.com when it is active; trust its CA
    # then. The herdr server normally runs without it and uses the system store.
    ctx = None
    ca = os.environ.get("NODE_EXTRA_CA_CERTS")
    if ca and os.path.isfile(ca):
        import ssl
        ctx = ssl.create_default_context(cafile=ca)
    try:
        with urllib.request.urlopen(req, timeout=8, context=ctx) as resp:
            data = json.load(resp)
    except Exception:
        return None

    five = (data.get("five_hour") or {}).get("utilization")
    seven = (data.get("seven_day") or {}).get("utilization")
    if five is None or seven is None:
        return None
    windows = [
        ("5", float(five), iso_epoch((data.get("five_hour") or {}).get("resets_at"))),
        ("W", float(seven), iso_epoch((data.get("seven_day") or {}).get("resets_at"))),
    ]
    fable = next(
        (l.get("percent") for l in data.get("limits") or []
         if l.get("kind") == "weekly_scoped"
         and (((l.get("scope") or {}).get("model") or {}).get("display_name") == "Fable")),
        None,
    )
    if fable is not None:
        windows.append(("F", float(fable), None))
    return windows


def codex_windows() -> list[tuple[str, float]] | None:
    """[(label, usedPercent)] for each reported window, in primary order."""
    try:
        proc = subprocess.Popen(
            ["codex", "-s", "read-only", "-a", "never", "app-server"],
            stdin=subprocess.PIPE, stdout=subprocess.PIPE,
            stderr=subprocess.DEVNULL, text=True,
        )
    except Exception:
        return None

    out: dict = {}

    def pump() -> None:
        def send(mid, method):
            proc.stdin.write(json.dumps({"jsonrpc": "2.0", "id": mid, "method": method, "params": {}}) + "\n")
            proc.stdin.flush()

        proc.stdin.write(json.dumps({
            "jsonrpc": "2.0", "id": 1, "method": "initialize",
            "params": {"clientInfo": {"name": "herdr-usage-bar", "title": "herdr", "version": "1"}},
        }) + "\n")
        proc.stdin.flush()
        for line in proc.stdout:
            try:
                msg = json.loads(line)
            except Exception:
                continue
            if msg.get("id") == 1:
                proc.stdin.write(json.dumps({"jsonrpc": "2.0", "method": "initialized", "params": {}}) + "\n")
                proc.stdin.flush()
                send(2, "account/rateLimits/read")
            elif msg.get("id") == 2:
                out["r"] = msg.get("result") or {}
                return

    t = threading.Thread(target=pump, daemon=True)
    t.start()
    t.join(12)
    try:
        proc.kill()
    except Exception:
        pass

    limits = (out.get("r") or {}).get("rateLimits") or {}
    windows = []
    for key in ("primary", "secondary"):
        block = limits.get(key) or {}
        pct = block.get("usedPercent")
        if pct is None:
            continue
        # codex reports resetsAt as epoch seconds; claude sends ISO.
        windows.append((window_label(block.get("windowDurationMins")), float(pct), block.get("resetsAt")))
    return windows or None


def segment(name: str, windows: list, stale: bool) -> str:
    windows = norm(windows)
    worst = max(w[1] for w in windows)
    # Only the window that is actually close to its limit says when it reopens;
    # below the warn threshold the reset is noise in a one-line bar.
    hot = max(windows, key=lambda w: w[1])
    when = reset_at(hot[2]) if worst >= WARN_PCT else ""
    icon = f"{mark(worst).strip()} " if mark(worst) else ""
    return f"{name} {icon}{render(windows)}{'*' if stale else ''}{when}"


def main() -> int:
    cache = load_cache()
    segments = []

    for name, key, ttl, fetch in (
        ("claude", "claude", CLAUDE_TTL, claude_windows),
        ("codex", "codex", CODEX_TTL, codex_windows),
    ):
        windows, stale = cached(cache, key, ttl, fetch)
        if windows:
            segments.append(segment(name, windows, stale))

    save_cache(cache)
    if not segments:
        return 1
    print(" │ ".join(segments))
    return 0


if __name__ == "__main__":
    sys.exit(main())
