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

A *fresh* bridge (post-reboot / post-restart) has an empty in-memory
completed-work set, so it accepts the re-queued session and spawns the worker on
its next poll (~2 s). The worktree does NOT need to pre-exist: on work-poll the
bridge does "Created agent worktree at <cwd> on branch worktree-bridge-<cse>"
before spawning, so it recreates a missing worktree from the session branch.
This matters because a *graceful* bridge stop (our ExecStop C-c, and every
watchdog restart) makes the bridge delete its worktrees on shutdown while
"Skipping archive+deregister to allow resume" — so the session stays resumable
but its worktree is gone by the time resume runs. (A hard reboot kills the bridge
before that cleanup, so there the worktree survives.) Either way, reconnect is
the right move: a genuinely-dead/archived session just fails the reconnect.

## The environment must be the SAME one the session was created under

reconnect is environment-scoped: hitting it with a session that belongs to a
different environment returns 400 "Session does not belong to this environment."
A bridge only keeps its environment across a restart when it writes
bridge-pointer.json, which requires --create-session-in-dir (see the long note
in claude-remote-control.nix). Without that the old environment is DELETED on
shutdown and every reconnect here fails 400 — that was the first live run:
revived=0 failed=3.

So the environment id is read from the bridge's own pointer file, the same
source the bridge itself uses to request reuseEnvironmentId:

    $CLAUDE_CONFIG_DIR/projects/<slugified dir>/bridge-pointer.json
      -> {"sessionId", "environmentId", "source": "standalone", "pid", ...}

Falling back to `GET /v1/environments` and picking the newest "<device>:*" is
kept only for the case where the pointer is missing; it is strictly worse, since
any other bridge on this box matches that prefix too.

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
BRIDGE_DIR = os.environ.get("CRC_BRIDGE_DIR", str(HOME / "nic-os"))
CONFIG_DIR = Path(os.environ.get("CRC_CONFIG_DIR", HOME / ".claude-rc"))
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


def cse_from_cwd(cwd):
    m = CSE_RE.search(cwd or "")
    return m.group(1) if m else None


def _slug(path):
    """claude-code's project-dir slug: every non-alphanumeric char -> '-'.
    Mirrors the slugify it uses for $CLAUDE_CONFIG_DIR/projects/<slug>/."""
    return re.sub(r"[^A-Za-z0-9]", "-", str(path))


def worktree_last_active(cwd):
    """Newest conversation-JSONL mtime for a bridge worktree's session (activity
    proxy). Bridge workers run with cwd=<worktree> and
    CLAUDE_CONFIG_DIR=~/.claude-rc, whose `projects` symlink points back into
    PROJECTS_DIR (~/.claude/projects), so the transcript lives at
    PROJECTS_DIR/<slug of cwd>/<uuid>.jsonl. Its mtime is bumped on every
    user/assistant message and survives a reboot -> unlike a live worker PID, it
    still marks an idle-but-resumable session as recently active."""
    d = PROJECTS_DIR / _slug(cwd)
    if not d.is_dir():
        return 0.0
    return max((p.stat().st_mtime for p in d.glob("*.jsonl")), default=0.0)


# ---------------------------------------------------------------- snapshot ----
def cmd_snapshot():
    """Record the recently-active bridge sessions so a later (restarted) instance
    knows what to revive.

    Enumerated from the on-disk bridge-cse_* worktrees + their transcript mtimes,
    NOT from live worker PIDs. A bridge worker process only exists while a session
    is mid-turn, so the old PID-based snapshot was empty almost always and a
    reboot revived nothing (revived=0 on every real reboot). The worktree dir and
    its transcript both survive a reboot, so keying off them captures the idle-
    but-resumable sessions that are the whole point of boot-resume. Bounded to the
    RECENCY window so an abandoned session ages out instead of being revived
    forever."""
    now = time.time()
    records = {}
    for wt in sorted(WORKTREES_DIR.glob("bridge-cse_*")):
        if not wt.is_dir():
            continue
        cse = cse_from_cwd(wt.name)
        if not cse:
            continue
        la = worktree_last_active(wt) or wt.stat().st_mtime
        if now - la > RECENCY:
            continue
        records[cse] = {
            "cseId": cse,
            "cwd": str(wt),
            "localUuid": None,
            "lastActive": la,
        }
    save_json(SNAPSHOT_FILE, {"savedAt": int(now), "sessions": list(records.values())})
    log(f"snapshot: {len(records)} recently-active session(s) -> {SNAPSHOT_FILE}")


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


def bridge_pointer_path():
    """$CLAUDE_CONFIG_DIR/projects/<slugified bridge dir>/bridge-pointer.json.

    Mirrors claude-code's own getBridgePointerPath(): join(configDir, "projects",
    dir.replace(/[^a-zA-Z0-9]/g, "-"), "bridge-pointer.json").
    """
    slug = re.sub(r"[^a-zA-Z0-9]", "-", BRIDGE_DIR)
    return CONFIG_DIR / "projects" / slug / "bridge-pointer.json"


def current_env_id(tok):
    """The environment the running bridge is actually serving.

    Preferred source is the bridge's own bridge-pointer.json — the same file it
    reads on start to request reuseEnvironmentId, so it is authoritative and
    needs no network call. Listing /v1/environments and taking the newest
    '<device>:*' is only a fallback: the name is '<device>:<basename>:<hash>',
    so a second bridge started anywhere else on this box (say a throwaway one in
    /tmp) also matches '<device>:' and, being newer, would win.
    """
    ptr = load_json(bridge_pointer_path(), {})
    env = ptr.get("environmentId") if isinstance(ptr, dict) else None
    if env:
        log(f"resume: environment {env} from bridge pointer {bridge_pointer_path()}")
        return env

    log("resume: no bridge pointer; falling back to /v1/environments listing")
    req = urllib.request.Request(f"{BASE}/v1/environments", headers=_headers(tok))
    d = json.loads(urllib.request.urlopen(req, timeout=20).read())
    items = d.get("data") or d.get("environments") or (d if isinstance(d, list) else [])
    prefix = f"{DEVICE_NAME}:{Path(BRIDGE_DIR).name}:"
    mine = [e for e in items if isinstance(e, dict) and str(e.get("name", "")).startswith(prefix)]
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

    revived = skipped_stale = skipped_cooldown = failed = 0
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
        # NOTE: intentionally do NOT skip when the worktree is missing. A graceful
        # bridge stop deletes the worktree but keeps the session resumable, and the
        # bridge recreates the worktree from its branch on the reconnected work
        # poll. Reconnect is the right move either way; a dead session just fails.
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
               f"failed={failed}")
    log(summary)
    if revived or failed:
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
