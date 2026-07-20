#!/usr/bin/env python3
"""claude-rc-autoresume — auto-resume rate-limited claude-rc bridge sessions.

The remote-control bridge (`claude remote-control --spawn worktree`) hosts each
remote session as a subprocess in its own git worktree, writing a conversation
JSONL. When a session hits the Claude usage cap it stalls; the bridge offers no
API to inject input, so this watcher resumes the conversation headlessly once
the cap window resets.

Per tick (driven by a systemd timer) it:
  1. Enumerates active bridge sessions from ~/.claude/sessions/*.json.
  2. Reads the tail of each session's conversation JSONL and detects a hard cap
     from either signal: a structured `rate_limit_event` with a *blocking*
     status, or an `isApiErrorMessage` assistant banner ("You've hit your
     session limit · resets 6pm"). resetsAt comes from the event or is parsed
     out of the banner text.
  3. Once now >= resetsAt + margin, and the conversation has not advanced past
     the cap event, it resumes the session:
       - DRY-RUN (default): logs + Telegram-notifies the planned resume.
       - LIVE: `claude -p --resume <sessionId> "<message>"` in the session cwd.
  4. A state file makes each (sessionId, resetsAt) act at most once.

The real hard cap does NOT arrive as a structured `rate_limit_event` — those
only carry warnings (status=allowed_warning, rateLimitType=seven_day). An actual
cap is an assistant message flagged isApiErrorMessage with the banner text
"You've hit your session limit · resets <time> (<tz>)", which detect_cap() now
matches and whose reset time parse_reset_epoch() extracts. CRC_DRY_RUN=1 logs
the planned resume instead of performing it.

Config is via environment (set by the NixOS service):
  CRC_DRY_RUN            "1" (default) = log/notify only; "0" = perform resume
  CRC_SESSIONS_DIR       default ~/.claude/sessions
  CRC_PROJECTS_DIR       default ~/.claude/projects
  CRC_STATE_FILE         default ~/.claude/state/claude-rc-autoresume/handled.json
  CRC_MARGIN_SECONDS     wait this long past resetsAt (default 60)
  CRC_BLOCKING_STATUSES  comma list of blocking rate_limit statuses
                         (default "overuse_denied")
  CRC_RESUME_MESSAGE     prompt sent on resume (default "continue")
  CRC_CLAUDE_BIN         path to the claude binary (live mode)
  CRC_TAIL_LINES         JSONL tail lines to scan (default 60)
  CRC_TELEGRAM_TOKEN_FILE / CRC_TELEGRAM_CHAT_ID  optional Telegram notify
"""
import json
import os
import re
import subprocess
import sys
import time
import urllib.request
from datetime import datetime, timedelta
from pathlib import Path

try:
    from zoneinfo import ZoneInfo
except ImportError:  # pragma: no cover — zoneinfo is stdlib on py>=3.9
    ZoneInfo = None

HOME = Path(os.environ.get("HOME", "/home/nsimon"))
DRY_RUN = os.environ.get("CRC_DRY_RUN", "1") != "0"
SESSIONS_DIR = Path(os.environ.get("CRC_SESSIONS_DIR", HOME / ".claude/sessions"))
PROJECTS_DIR = Path(os.environ.get("CRC_PROJECTS_DIR", HOME / ".claude/projects"))
STATE_FILE = Path(
    os.environ.get("CRC_STATE_FILE", HOME / ".claude/state/claude-rc-autoresume/handled.json")
)
MARGIN = int(os.environ.get("CRC_MARGIN_SECONDS", "60"))
BLOCKING = {
    s.strip()
    for s in os.environ.get("CRC_BLOCKING_STATUSES", "overuse_denied").split(",")
    if s.strip()
}
RESUME_MSG = os.environ.get("CRC_RESUME_MESSAGE", "continue")
CLAUDE_BIN = os.environ.get(
    "CRC_CLAUDE_BIN",
    str(HOME / ".local/state/nix/profiles/home-manager/home-path/bin/claude"),
)
TAIL_LINES = int(os.environ.get("CRC_TAIL_LINES", "60"))
TG_TOKEN_FILE = os.environ.get("CRC_TELEGRAM_TOKEN_FILE", "")
TG_CHAT_ID = os.environ.get("CRC_TELEGRAM_CHAT_ID", "")


def log(msg):
    print(f"[claude-rc-autoresume] {msg}", flush=True)


def telegram(msg):
    if not (TG_TOKEN_FILE and TG_CHAT_ID and os.path.exists(TG_TOKEN_FILE)):
        return
    try:
        token = Path(TG_TOKEN_FILE).read_text().strip()
        data = json.dumps({"chat_id": TG_CHAT_ID, "text": msg}).encode()
        req = urllib.request.Request(
            f"https://api.telegram.org/bot{token}/sendMessage",
            data=data,
            headers={"Content-Type": "application/json"},
        )
        urllib.request.urlopen(req, timeout=10).read()
    except Exception as e:  # noqa: BLE001 — notification is best-effort
        log(f"telegram notify failed: {e}")


def load_state():
    try:
        return json.loads(STATE_FILE.read_text())
    except Exception:  # noqa: BLE001
        return {}


def save_state(state):
    STATE_FILE.parent.mkdir(parents=True, exist_ok=True)
    tmp = STATE_FILE.with_suffix(".tmp")
    tmp.write_text(json.dumps(state, indent=2))
    tmp.replace(STATE_FILE)


def jsonl_path_for(cwd, session_id):
    """Conversation JSONL: ~/.claude/projects/<cwd with / and . -> ->/<sid>.jsonl"""
    slug = cwd.replace("/", "-").replace(".", "-")
    p = PROJECTS_DIR / slug / f"{session_id}.jsonl"
    if p.exists():
        return p
    # Fallback: search by session id (slug derivation can drift across versions).
    hits = list(PROJECTS_DIR.glob(f"*/{session_id}.jsonl"))
    return hits[0] if hits else None


def tail_lines(path, n):
    try:
        with open(path, "rb") as f:
            f.seek(0, os.SEEK_END)
            size = f.tell()
            block = min(size, 65536)
            f.seek(size - block)
            data = f.read().decode("utf-8", "replace")
        return data.splitlines()[-n:]
    except Exception as e:  # noqa: BLE001
        log(f"tail {path} failed: {e}")
        return []


# The bridge writes a real hard-cap NOT as a structured rate_limit_event but as
# an assistant message flagged isApiErrorMessage whose text is the human banner
# "You've hit your session limit · resets 6pm (Europe/Paris)". Structured
# rate_limit_event records only ever carry *warnings* (status=allowed_warning,
# rateLimitType=seven_day). So we detect both: a structured event with a
# blocking status, or the banner (and parse its reset time from the text).
BANNER_RE = re.compile(
    r"(?:hit|reached|exceeded)\b.{0,40}?\blimit\b"  # "hit your session limit"
    r"|usage limit"
    r"|rate limit"
    r"|out of\b.{0,20}?usage",
    re.I | re.S,
)
_RESET_ABS_RE = re.compile(
    r"resets?\s+(?:at\s+)?(\d{1,2})(?::(\d{2}))?\s*([ap]m)\b", re.I
)
_RESET_REL_RE = re.compile(
    r"(?:resets?\s+in|try again in)\s+(\d+)\s*(hours?|minutes?|h|m)\b", re.I
)
_TZ_RE = re.compile(r"\(([A-Za-z]+(?:/[A-Za-z_+-]+)?)\)")


def parse_reset_epoch(text, now=None):
    """Parse a reset time out of a cap banner into an epoch (UTC seconds), or None.

    Handles "resets 6pm (Europe/Paris)", "resets at 3:30pm (UTC)", "Resets 2pm"
    (no tz -> local), and relative "resets in 5 hours". Absolute times resolve to
    the next future occurrence in the stated timezone. Returns None if no time is
    parseable, so the caller never resumes on an unknown reset window.
    """
    rel = _RESET_REL_RE.search(text)
    if rel:
        n = int(rel.group(1))
        unit = rel.group(2).lower()
        secs = n * 3600 if unit.startswith("h") else n * 60
        return int((now.timestamp() if now else time.time())) + secs

    m = _RESET_ABS_RE.search(text)
    if not m:
        return None
    hour = int(m.group(1)) % 12
    if m.group(3).lower() == "pm":
        hour += 12
    minute = int(m.group(2) or 0)

    tz = None
    tzm = _TZ_RE.search(text)
    if tzm and ZoneInfo:
        try:
            tz = ZoneInfo(tzm.group(1))
        except Exception:  # noqa: BLE001 — unknown tz -> fall back to local
            tz = None
    if now is None:
        base = datetime.now(tz)
    else:
        # Anchor to when the cap occurred (the banner's own timestamp), in the
        # reset's timezone, so "resets 6pm" resolves to the same-day 6pm even
        # when we detect the cap a few minutes/hours later.
        base = now.astimezone(tz) if tz else now
    target = base.replace(hour=hour, minute=minute, second=0, microsecond=0)
    if target <= base:
        target += timedelta(days=1)
    return int(target.timestamp())


def _message_text(obj):
    msg = obj.get("message") or {}
    content = msg.get("content")
    if isinstance(content, str):
        return content
    if isinstance(content, list):
        return " ".join(
            b.get("text", "")
            for b in content
            if isinstance(b, dict) and b.get("type") == "text"
        )
    return ""


def _is_api_error(obj):
    msg = obj.get("message") or {}
    return bool(obj.get("isApiErrorMessage") or msg.get("isApiErrorMessage"))


def _parse_ts(ts):
    """Parse a JSONL record's ISO-8601 timestamp into an aware datetime, or None."""
    if not ts:
        return None
    try:
        return datetime.fromisoformat(ts.replace("Z", "+00:00"))
    except Exception:  # noqa: BLE001
        return None


def detect_cap(lines):
    """Return (resets_at, label) for the most recent hard cap, or None.

    Scans newest-first for either a blocking structured rate_limit_event or an
    isApiErrorMessage banner. Non-blocking structured events (warnings) are
    skipped so an older real cap below them is still found. resets_at may be None
    when a banner's reset time can't be parsed — the caller then skips rather
    than resuming blind.
    """
    for line in reversed(lines):
        if "rate_limit_event" not in line and "isApiErrorMessage" not in line:
            continue
        try:
            obj = json.loads(line)
        except Exception:  # noqa: BLE001
            continue

        info = obj.get("rate_limit_info") or {}
        if obj.get("type") == "rate_limit_event" and info:
            status = info.get("status")
            if status in BLOCKING and info.get("resetsAt"):
                return (int(info["resetsAt"]), f"event:{status}:{info.get('rateLimitType')}")
            continue  # warning/non-blocking — keep scanning older lines

        if _is_api_error(obj):
            text = _message_text(obj)
            if text and BANNER_RE.search(text):
                anchor = _parse_ts(obj.get("timestamp"))
                return (parse_reset_epoch(text, now=anchor), f"banner:{text.strip()[:70]}")
    return None


def proc_alive(pid):
    try:
        os.kill(int(pid), 0)
        return True
    except Exception:  # noqa: BLE001
        return False


def resume(session, jsonl):
    sid = session["sessionId"]
    cwd = session["cwd"]
    pid = session.get("pid")
    if DRY_RUN:
        log(f"DRY-RUN: would resume {sid} (cwd={cwd}) with: {CLAUDE_BIN} -p --resume {sid} {RESUME_MSG!r}")
        telegram(f"🔁 [dry-run] claude-rc cap cleared — would resume session {sid[:8]} ({Path(cwd).name})")
        return
    # Live: the idle bridge subprocess still "owns" the session id. Stop it
    # first so the headless resume is the sole writer of the conversation.
    if pid and proc_alive(pid):
        log(f"stopping idle bridge subprocess pid={pid} for {sid}")
        try:
            os.kill(int(pid), 15)  # SIGTERM
            time.sleep(3)
        except Exception as e:  # noqa: BLE001
            log(f"could not stop pid {pid}: {e}")
    log(f"resuming {sid} headlessly")
    try:
        subprocess.run(
            [CLAUDE_BIN, "-p", "--resume", sid, RESUME_MSG],
            cwd=cwd,
            timeout=900,
            check=False,
        )
        telegram(f"✅ claude-rc auto-resumed session {sid[:8]} ({Path(cwd).name}) after cap reset")
    except Exception as e:  # noqa: BLE001
        log(f"resume of {sid} failed: {e}")
        telegram(f"⚠️ claude-rc resume of {sid[:8]} failed: {e}")


def main():
    state = load_state()
    now = int(time.time())
    if not SESSIONS_DIR.is_dir():
        log(f"no sessions dir at {SESSIONS_DIR}; nothing to do")
        return
    n_sessions = n_capped = n_acted = 0
    for meta_file in SESSIONS_DIR.glob("*.json"):
        try:
            session = json.loads(meta_file.read_text())
        except Exception:  # noqa: BLE001
            continue
        sid = session.get("sessionId")
        cwd = session.get("cwd")
        if not (sid and cwd):
            continue
        n_sessions += 1
        jsonl = jsonl_path_for(cwd, sid)
        if not jsonl:
            continue
        cap = detect_cap(tail_lines(jsonl, TAIL_LINES))
        if not cap:
            continue
        resets_at, label = cap
        log(f"session {sid[:8]}: cap detected [{label}] resetsAt={resets_at}")
        if not resets_at:
            # Banner matched but its reset time was unparseable — never resume
            # blind (we'd risk hammering an unreset cap). Surface it and move on.
            log(f"session {sid[:8]}: reset time unparseable — skipping")
            continue
        n_capped += 1
        key = f"{sid}:{resets_at}"
        if state.get(key):
            continue  # already handled this cap window
        if now < int(resets_at) + MARGIN:
            wait = int(resets_at) + MARGIN - now
            log(f"session {sid[:8]} capped [{label}]; reset in {wait}s — waiting")
            continue
        # Reset window has passed: act once, and only if not already advanced.
        resume(session, jsonl)
        state[key] = {"sessionId": sid, "cwd": cwd, "resetsAt": resets_at, "label": label, "actedAt": now, "dryRun": DRY_RUN}
        n_acted += 1
    save_state(state)
    log(f"tick done: sessions={n_sessions} capped={n_capped} acted={n_acted} dry_run={DRY_RUN}")


if __name__ == "__main__":
    sys.exit(main())
