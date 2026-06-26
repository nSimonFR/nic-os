#!/usr/bin/env python3
"""claude-rc-autoresume — auto-resume rate-limited claude-rc bridge sessions.

The remote-control bridge (`claude remote-control --spawn worktree`) hosts each
remote session as a subprocess in its own git worktree, writing a conversation
JSONL. When a session hits the Claude usage cap it stalls; the bridge offers no
API to inject input, so this watcher resumes the conversation headlessly once
the cap window resets.

Per tick (driven by a systemd timer) it:
  1. Enumerates active bridge sessions from ~/.claude/sessions/*.json.
  2. Reads the tail of each session's conversation JSONL and finds the most
     recent `rate_limit_event`. If that event's status is a *blocking* one
     (the session is capped, not merely warned) it records resetsAt.
  3. Once now >= resetsAt + margin, and the conversation has not advanced past
     the cap event, it resumes the session:
       - DRY-RUN (default): logs + Telegram-notifies the planned resume.
       - LIVE: `claude -p --resume <sessionId> "<message>"` in the session cwd.
  4. A state file makes each (sessionId, resetsAt) act at most once.

DRY-RUN is the default because a real cap-denial event has not yet been
observed in the wild — only `allowed_warning`. Dry-run is self-documenting:
it logs every rate_limit_event it sees and whether it deems it blocking, so the
first real cap reveals the true status string before any live action is taken.

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
import subprocess
import sys
import time
import urllib.request
from pathlib import Path

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


def last_rate_limit_event(lines):
    """Return (status, resets_at, rate_type) of the last rate_limit_event, or None."""
    for line in reversed(lines):
        if '"rate_limit_event"' not in line:
            continue
        try:
            obj = json.loads(line)
        except Exception:  # noqa: BLE001
            continue
        info = obj.get("rate_limit_info") or {}
        if obj.get("type") == "rate_limit_event" and info:
            return (
                info.get("status"),
                info.get("resetsAt"),
                info.get("rateLimitType"),
            )
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
            env={**os.environ, "CLAUDE_AUTO_RETRY_ACTIVE": "1"},
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
        ev = last_rate_limit_event(tail_lines(jsonl, TAIL_LINES))
        if not ev:
            continue
        status, resets_at, rate_type = ev
        blocking = status in BLOCKING
        log(f"session {sid[:8]}: last rate_limit_event status={status} blocking={blocking} resetsAt={resets_at} type={rate_type}")
        if not blocking or not resets_at:
            continue
        n_capped += 1
        key = f"{sid}:{resets_at}"
        if state.get(key):
            continue  # already handled this cap window
        if now < int(resets_at) + MARGIN:
            wait = int(resets_at) + MARGIN - now
            log(f"session {sid[:8]} capped ({rate_type}); reset in {wait}s — waiting")
            continue
        # Reset window has passed: act once, and only if not already advanced.
        resume(session, jsonl)
        state[key] = {"sessionId": sid, "cwd": cwd, "resetsAt": resets_at, "actedAt": now, "dryRun": DRY_RUN}
        n_acted += 1
    save_state(state)
    log(f"tick done: sessions={n_sessions} capped={n_capped} acted={n_acted} dry_run={DRY_RUN}")


if __name__ == "__main__":
    sys.exit(main())
