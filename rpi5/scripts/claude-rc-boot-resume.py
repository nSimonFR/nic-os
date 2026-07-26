#!/usr/bin/env python3
"""claude-rc-boot-resume — re-host previously-live Remote Control sessions when
the bridge (re)starts, so a reboot or a watchdog restart does not leave every
session dead until the user pokes it from the app.

## Why the obvious approaches don't work (all verified live on claude-code 2.1.202)

A `claude remote-control` bridge only spawns a worker for a session when the
Anthropic server hands that session to it as *work* on its `work/poll` loop.

  - `claude -p --resume <uuid>`  -> talks to the wrong endpoint; the transcript
    grows locally but the session never surfaces in the app. (This is why the
    old cap-autoresume was a silent no-op.)
  - POST /v1/code/sessions/<cse>/events (inject a "continue" user message) and
    POST .../client/presence  -> both return 200 but the bridge never reacts;
    an untrusted out-of-band client cannot make the server enqueue work.

## What DOES work — the environments reconnect endpoint

The bridge itself re-queues a session it owns via the environments API. Called
locally with the account's own OAuth token, it enqueues the session as work for
whichever bridge currently owns that environment:

    POST /v1/environments/<envId>/bridge/reconnect   {"session_id": "cse_..."}
    headers: Authorization: Bearer <oauth>, anthropic-version: 2023-06-01,
             anthropic-beta: environments-2025-11-01

The current environment id comes from a clean list call (no process memory, no
device token needed — plain OAuth is accepted):

    GET /v1/environments   -> pick the newest whose name starts "<device>:"
                              (the bridge registers e.g. "rpi5:nic-os:<hash>")

A *fresh* bridge (post-reboot / post-restart) has an empty in-memory
completed-work set, so it accepts the re-queued session and spawns the worker on
its next poll (~2 s). The worktree must still exist on disk (it does right after
boot/restart — this unit runs before the orphan-worktree cleanup timer).

The OAuth token is read from the bridge's own config dir (~/.claude-rc), which
`claude` keeps fresh — NOT ~/.claude, whose copy goes stale (see the
credentials-symlink-divergence note).

## Subcommands
  snapshot  record currently-live sdk-cli sessions -> snapshot.json (atomic)
  resume    on bridge start, reconnect each recently-live session

Config via environment (set by the NixOS unit); see the CRC_* defaults below.
CRC_DRY_RUN=1 logs the planned reconnects instead of performing them.
"""
import json
import os
import re
import sys
import time
import urllib.request
import urllib.error
from pathlib import Path

HOME = Path(os.environ.get("HOME", "/home/nsimon"))
DRY_RUN = os.environ.get("CRC_DRY_RUN", "1") != "0"
SESSIONS_DIR = Path(os.environ.get("CRC_SESSIONS_DIR", HOME / ".claude/sessions"))
PROJECTS_DIR = Path(os.environ.get("CRC_PROJECTS_DIR", HOME / ".claude/projects"))
SNAPSHOT_FILE = Path(os.environ.get("CRC_SNAPSHOT_FILE", HOME / ".claude/state/claude-rc-boot-resume/snapshot.json"))
STATE_FILE = Path(os.environ.get("CRC_STATE_FILE", HOME / ".claude/state/claude-rc-boot-resume/handled.json"))
CRED_FILE = Path(os.environ.get("CRC_CREDENTIALS_FILE", HOME / ".claude-rc/.credentials.json"))
WORKTREES_DIR = Path(os.environ.get("CRC_WORKTREES_DIR", HOME / "nic-os/.claude/worktrees"))
DEVICE_NAME = os.environ.get("CRC_DEVICE_NAME", "rpi5")
ORG_UUID = os.environ.get("CRC_ORG_UUID", "")
BASE = os.environ.get("CRC_API_BASE", "https://api.anthropic.com")
BETA = os.environ.get("CRC_ENVIRONMENTS_BETA", "environments-2025-11-01")

START_DELAY = int(os.environ.get("CRC_START_DELAY", "18"))     # let the bridge register its env + warm its poll loop
DELAY = int(os.environ.get("CRC_DELAY_SECONDS", "20"))          # between reconnects (spawns a ~70-200MB worker each; rpi5 has 3.9GB)
MAX_REVIVE = int(os.environ.get("CRC_MAX_REVIVE", "6"))         # leave headroom under bridge capacity 8
RECENCY = int(os.environ.get("CRC_RECENCY_SECONDS", "86400"))   # only revive sessions active within 24h (matches cleanup reap window)
COOLDOWN = int(os.environ.get("CRC_COOLDOWN_SECONDS", "600"))   # don't re-revive the same session within 10min (rapid restart loops)
TG_TOKEN_FILE = os.environ.get("CRC_TELEGRAM_TOKEN_FILE", "")
TG_CHAT_ID = os.environ.get("CRC_TELEGRAM_CHAT_ID", "")

CSE_RE = re.compile(r"bridge-(cse_[A-Za-z0-9]+)")


def log(msg):
    print(f"[claude-rc-boot-resume] {msg}", flush=True)


def telegram(msg):
    if not (TG_TOKEN_FILE and TG_CHAT_ID and os.path.exists(TG_TOKEN_FILE)):
        return
    try:
        token = Path(TG_TOKEN_FILE).read_text().strip()
        data = json.dumps({"chat_id": TG_CHAT_ID, "text": msg}).encode()
        req = urllib.request.Request(
            f"https://api.telegram.org/bot{token}/sendMessage",
            data=data, headers={"Content-Type": "application/json"},
        )
        urllib.request.urlopen(req, timeout=10).read()
    except Exception as e:  # noqa: BLE001 — best effort
        log(f"telegram notify failed: {e}")


def load_json(path, default):
    try:
        return json.loads(Path(path).read_text())
    except Exception:  # noqa: BLE001
        return default


def save_json(path, obj):
    path = Path(path)
    path.parent.mkdir(parents=True, exist_ok=True)
    tmp = path.with_suffix(".tmp")
    tmp.write_text(json.dumps(obj, indent=2))
    tmp.replace(path)


def pid_alive(pid):
    try:
        return Path(f"/proc/{int(pid)}").exists()
    except Exception:  # noqa: BLE001
        return False


def cse_from_cwd(cwd):
    m = CSE_RE.search(cwd or "")
    return m.group(1) if m else None


def conv_mtime(session_id, cwd):
    """Latest conversation-JSONL mtime for a session (activity proxy)."""
    hits = list(PROJECTS_DIR.glob(f"*/{session_id}.jsonl"))
    if not hits and cwd:
        slug = cwd.replace("/", "-").replace(".", "-").replace("_", "-")
        p = PROJECTS_DIR / slug / f"{session_id}.jsonl"
        if p.exists():
            hits = [p]
    return max((h.stat().st_mtime for h in hits), default=0.0)


# ---------------------------------------------------------------- snapshot ----
def cmd_snapshot():
    """Record the currently-live bridge sessions so a later (restarted) instance
    knows what to revive. Only PID-alive sdk-cli sessions are captured, so the
    snapshot always means 'these were live', never stale history."""
    records = {}
    for f in sorted(SESSIONS_DIR.glob("*.json")):
        s = load_json(f, None)
        if not isinstance(s, dict) or s.get("entrypoint") != "sdk-cli":
            continue
        if not pid_alive(s.get("pid")):
            continue
        cwd = s.get("cwd", "")
        cse = cse_from_cwd(cwd)
        if not cse:
            continue
        records[cse] = {
            "cseId": cse,
            "cwd": cwd,
            "localUuid": s.get("sessionId"),
            "lastActive": conv_mtime(s.get("sessionId"), cwd),
        }
    save_json(SNAPSHOT_FILE, {"savedAt": int(time.time()), "sessions": list(records.values())})
    log(f"snapshot: {len(records)} live session(s) -> {SNAPSHOT_FILE}")


# ------------------------------------------------------------------ resume ----
def oauth_token():
    return json.load(open(CRED_FILE))["claudeAiOauth"]["accessToken"]


def _headers(tok):
    h = {
        "Authorization": f"Bearer {tok}",
        "Content-Type": "application/json",
        "anthropic-version": "2023-06-01",
        "anthropic-beta": BETA,
    }
    if ORG_UUID:
        h["x-organization-uuid"] = ORG_UUID
    return h


def current_env_id(tok):
    """Newest environment whose name starts '<device>:' — the running bridge's."""
    req = urllib.request.Request(f"{BASE}/v1/environments", headers=_headers(tok))
    d = json.loads(urllib.request.urlopen(req, timeout=20).read())
    items = d.get("data") or d.get("environments") or (d if isinstance(d, list) else [])
    mine = [e for e in items if isinstance(e, dict) and str(e.get("name", "")).startswith(DEVICE_NAME + ":")]
    if not mine:
        return None
    mine.sort(key=lambda e: e.get("created_at", ""), reverse=True)
    return mine[0].get("id")


def reconnect(tok, env_id, cse):
    body = json.dumps({"session_id": cse}).encode()
    req = urllib.request.Request(
        f"{BASE}/v1/environments/{env_id}/bridge/reconnect",
        data=body, method="POST", headers=_headers(tok),
    )
    try:
        r = urllib.request.urlopen(req, timeout=20)
        return r.status, ""
    except urllib.error.HTTPError as e:
        return e.code, e.read().decode()[:200]


def cmd_resume():
    if START_DELAY:
        time.sleep(START_DELAY)
    snap = load_json(SNAPSHOT_FILE, {})
    sessions = snap.get("sessions", []) if isinstance(snap, dict) else []
    if not sessions:
        log("resume: empty snapshot, nothing to do")
        return
    state = load_json(STATE_FILE, {})
    now = int(time.time())

    try:
        tok = oauth_token()
    except Exception as e:  # noqa: BLE001
        log(f"resume: cannot read OAuth token from {CRED_FILE}: {e}")
        telegram(f"⚠️ claude-rc boot-resume: no OAuth token ({e}) — sessions not revived")
        return
    try:
        env_id = current_env_id(tok)
    except Exception as e:  # noqa: BLE001
        log(f"resume: GET /v1/environments failed: {e}")
        telegram(f"⚠️ claude-rc boot-resume: environment lookup failed ({e})")
        return
    if not env_id:
        log(f"resume: no environment named '{DEVICE_NAME}:*' found — bridge not registered yet?")
        return
    log(f"resume: environment={env_id} dry_run={DRY_RUN} candidates={len(sessions)}")

    revived = skipped_stale = skipped_cooldown = skipped_noworktree = failed = 0
    done = []
    for rec in sorted(sessions, key=lambda r: r.get("lastActive", 0), reverse=True):
        if revived >= MAX_REVIVE:
            log(f"resume: hit MAX_REVIVE={MAX_REVIVE}; {len(sessions) - MAX_REVIVE} not revived this run")
            break
        cse = rec.get("cseId")
        cwd = rec.get("cwd", "")
        if not cse:
            continue
        if now - int(rec.get("lastActive", 0)) > RECENCY:
            skipped_stale += 1
            continue
        key = f"{cse}:{env_id}"
        if now - int(state.get(key, {}).get("revivedAt", 0)) < COOLDOWN:
            skipped_cooldown += 1
            continue
        if cwd and not Path(cwd).is_dir():
            log(f"resume: worktree gone for {cse[:12]} ({cwd}) — skipping")
            skipped_noworktree += 1
            continue
        if DRY_RUN:
            log(f"DRY-RUN: would reconnect {cse} (cwd={Path(cwd).name})")
            revived += 1
            done.append(cse)
            continue
        s, err = reconnect(tok, env_id, cse)
        if s in (200, 201, 202, 204):
            log(f"reconnect {cse[:12]} -> HTTP {s} OK")
            state[key] = {"cseId": cse, "revivedAt": now}
            revived += 1
            done.append(cse)
            if revived < MAX_REVIVE:
                time.sleep(DELAY)
        else:
            log(f"reconnect {cse[:12]} -> HTTP {s} {err}")
            failed += 1

    save_json(STATE_FILE, state)
    summary = (f"{'[dry-run] ' if DRY_RUN else ''}claude-rc boot-resume: "
               f"revived={revived} stale={skipped_stale} cooldown={skipped_cooldown} "
               f"noWorktree={skipped_noworktree} failed={failed}")
    log(summary)
    if revived or failed or skipped_noworktree:
        short = ", ".join(c[4:12] for c in done)
        telegram(f"🔁 {summary}" + (f"\nrevived: {short}" if short else ""))


def main():
    cmd = sys.argv[1] if len(sys.argv) > 1 else "resume"
    if cmd == "snapshot":
        cmd_snapshot()
    elif cmd == "resume":
        cmd_resume()
    else:
        print(__doc__)
        sys.exit(2)


if __name__ == "__main__":
    main()
