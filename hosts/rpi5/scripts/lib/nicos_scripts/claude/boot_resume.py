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
`claude` keeps fresh — NOT ~/.claude, whose copy is left blanked once a refresh
severs the symlink between them. That dir is now the declared owner repo-wide
(claude-remote-control.nix `credentialsFiles`,
docs/adr/0007-claude-credentials-owner.md).

## Subcommands
  snapshot  record currently-live sdk-cli sessions -> snapshot.json (atomic)
  resume    on bridge start, reconnect each recently-live session

Config via environment (set by the NixOS unit); see the CRC_* defaults below.
CRC_DRY_RUN=1 (the default) logs the planned reconnects instead of performing them.
"""

import json
import os
import re
import subprocess
import sys
import time
import urllib.error
import urllib.request
from dataclasses import dataclass
from pathlib import Path

from ..logs import logger
from ..secrets import env_int, env_str, read_secret

log = logger("claude-rc-boot-resume")

CSE_RE = re.compile(r"bridge-(cse_[A-Za-z0-9]+)")
OK_STATUS = (200, 201, 202, 204)


@dataclass(frozen=True)
class Config:
    home: Path = Path("/home/nsimon")
    # Defaults to a DRY RUN: this spawns bridge workers (~70-200 MB each) on a
    # 3.9 GB box, so live reconnects have to be asked for explicitly.
    dry_run: bool = True
    sessions_dir: Path = None
    projects_dir: Path = None
    snapshot_file: Path = None
    state_file: Path = None
    cred_file: Path = None
    worktrees_dir: Path = None
    device_name: str = "rpi5"
    bridge_dir: str = ""
    config_dir: Path = None
    org_uuid: str = ""
    base: str = "https://api.anthropic.com"
    beta: str = "environments-2025-11-01"
    start_delay: int = 18   # let the bridge register its env + warm its poll loop
    delay: int = 20         # between reconnects (each spawns a worker)
    max_revive: int = 6     # leave headroom under bridge capacity 8
    recency: int = 86400    # only revive sessions active within 24h
    cooldown: int = 600     # don't re-revive the same session within 10min
    # The one-shot seam (shared/notify.nix `send`), already carrying the bot-token
    # path and chat id. See telegram() below.
    telegram_send: str = ""

    @classmethod
    def from_env(cls, env=None):
        home = Path(env_str("HOME", "/home/nsimon", env) or "/home/nsimon")

        def path_of(name, default):
            return Path(env_str(name, "", env) or default)

        bridge_dir = env_str("CRC_BRIDGE_DIR", str(home / "nic-os"), env)
        return cls(
            home=home,
            dry_run=env_str("CRC_DRY_RUN", "1", env) != "0",
            sessions_dir=path_of("CRC_SESSIONS_DIR", home / ".claude/sessions"),
            projects_dir=path_of("CRC_PROJECTS_DIR", home / ".claude/projects"),
            snapshot_file=path_of(
                "CRC_SNAPSHOT_FILE",
                home / ".claude/state/claude-rc-boot-resume/snapshot.json"),
            state_file=path_of(
                "CRC_STATE_FILE",
                home / ".claude/state/claude-rc-boot-resume/handled.json"),
            # ~/.claude-rc, NOT ~/.claude — the latter's copy goes stale.
            cred_file=path_of("CRC_CREDENTIALS_FILE", home / ".claude-rc/.credentials.json"),
            worktrees_dir=path_of("CRC_WORKTREES_DIR", home / "nic-os/.claude/worktrees"),
            device_name=env_str("CRC_DEVICE_NAME", "rpi5", env),
            bridge_dir=bridge_dir,
            config_dir=path_of("CRC_CONFIG_DIR", home / ".claude-rc"),
            org_uuid=env_str("CRC_ORG_UUID", "", env),
            base=env_str("CRC_API_BASE", "https://api.anthropic.com", env),
            beta=env_str("CRC_ENVIRONMENTS_BETA", "environments-2025-11-01", env),
            start_delay=env_int("CRC_START_DELAY", 18, env),
            delay=env_int("CRC_DELAY_SECONDS", 20, env),
            max_revive=env_int("CRC_MAX_REVIVE", 6, env),
            recency=env_int("CRC_RECENCY_SECONDS", 86400, env),
            cooldown=env_int("CRC_COOLDOWN_SECONDS", 600, env),
            telegram_send=env_str("CRC_TELEGRAM_SEND", "", env),
        )

    def headers(self, tok):
        h = {
            "Authorization": f"Bearer {tok}",
            "Content-Type": "application/json",
            "anthropic-version": "2023-06-01",
            "anthropic-beta": self.beta,
        }
        if self.org_uuid:
            h["x-organization-uuid"] = self.org_uuid
        return h


def telegram(cfg, msg, run=None):
    """Post the boot-resume summary through the shared one-shot sender.

    --mode plain because these messages carry session names and worktree paths
    that are not HTML-escaped; asking Telegram to parse them as HTML is how a
    stray "<" turns the whole notification into a 400. Unset CRC_TELEGRAM_SEND
    (running this script by hand) → no-op.
    """
    if not cfg.telegram_send:
        return
    try:
        (run or subprocess.run)(
            [cfg.telegram_send, "--mode", "plain", msg],
            stdout=subprocess.DEVNULL, timeout=30, check=False,
        )
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


def slug(path):
    """claude-code's project-dir slug: every non-alphanumeric char -> '-'.
    Mirrors the slugify it uses for $CLAUDE_CONFIG_DIR/projects/<slug>/."""
    return re.sub(r"[^A-Za-z0-9]", "-", str(path))


def worktree_last_active(cfg, cwd):
    """Newest conversation-JSONL mtime for a bridge worktree's session (activity
    proxy). Bridge workers run with cwd=<worktree> and
    CLAUDE_CONFIG_DIR=~/.claude-rc, whose `projects` symlink points back into
    PROJECTS_DIR (~/.claude/projects), so the transcript lives at
    PROJECTS_DIR/<slug of cwd>/<uuid>.jsonl. Its mtime is bumped on every
    user/assistant message and survives a reboot -> unlike a live worker PID, it
    still marks an idle-but-resumable session as recently active."""
    d = cfg.projects_dir / slug(cwd)
    if not d.is_dir():
        return 0.0
    return max((p.stat().st_mtime for p in d.glob("*.jsonl")), default=0.0)


# ---------------------------------------------------------------- snapshot ----

def cmd_snapshot(cfg, now=None):
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
    now = time.time() if now is None else now
    records = {}
    for wt in sorted(cfg.worktrees_dir.glob("bridge-cse_*")):
        if not wt.is_dir():
            continue
        cse = cse_from_cwd(wt.name)
        if not cse:
            continue
        la = worktree_last_active(cfg, wt) or wt.stat().st_mtime
        if now - la > cfg.recency:
            continue
        records[cse] = {
            "cseId": cse,
            "cwd": str(wt),
            "localUuid": None,
            "lastActive": la,
        }
    save_json(cfg.snapshot_file, {"savedAt": int(now), "sessions": list(records.values())})
    log(f"snapshot: {len(records)} recently-active session(s) -> {cfg.snapshot_file}")
    return records


# ------------------------------------------------------------------ resume ----

def oauth_token(cfg):
    return json.loads(cfg.cred_file.read_text())["claudeAiOauth"]["accessToken"]


def bridge_pointer_path(cfg):
    """$CLAUDE_CONFIG_DIR/projects/<slugified bridge dir>/bridge-pointer.json.

    Mirrors claude-code's own getBridgePointerPath(): join(configDir, "projects",
    dir.replace(/[^a-zA-Z0-9]/g, "-"), "bridge-pointer.json").
    """
    return cfg.config_dir / "projects" / slug(cfg.bridge_dir) / "bridge-pointer.json"


def current_env_id(cfg, tok, opener=None):
    """The environment the running bridge is actually serving.

    Preferred source is the bridge's own bridge-pointer.json — the same file it
    reads on start to request reuseEnvironmentId, so it is authoritative and
    needs no network call. Listing /v1/environments and taking the newest
    '<device>:*' is only a fallback: the name is '<device>:<basename>:<hash>',
    so a second bridge started anywhere else on this box (say a throwaway one in
    /tmp) also matches '<device>:' and, being newer, would win.
    """
    ptr = load_json(bridge_pointer_path(cfg), {})
    env = ptr.get("environmentId") if isinstance(ptr, dict) else None
    if env:
        log(f"resume: environment {env} from bridge pointer {bridge_pointer_path(cfg)}")
        return env

    log("resume: no bridge pointer; falling back to /v1/environments listing")
    req = urllib.request.Request(f"{cfg.base}/v1/environments", headers=cfg.headers(tok))
    d = json.loads((opener or urllib.request.urlopen)(req, timeout=20).read())
    items = d.get("data") or d.get("environments") or (d if isinstance(d, list) else [])
    prefix = f"{cfg.device_name}:{Path(cfg.bridge_dir).name}:"
    mine = [e for e in items if isinstance(e, dict) and str(e.get("name", "")).startswith(prefix)]
    if not mine:
        return None
    mine.sort(key=lambda e: e.get("created_at", ""), reverse=True)
    return mine[0].get("id")


def reconnect(cfg, tok, env_id, cse, opener=None):
    body = json.dumps({"session_id": cse}).encode()
    req = urllib.request.Request(
        f"{cfg.base}/v1/environments/{env_id}/bridge/reconnect",
        data=body, method="POST", headers=cfg.headers(tok),
    )
    try:
        r = (opener or urllib.request.urlopen)(req, timeout=20)
        return r.status, ""
    except urllib.error.HTTPError as e:
        return e.code, e.read().decode()[:200]


def cmd_resume(cfg, opener=None, sleep=time.sleep, now=None, notify=None):
    notify = notify or (lambda msg: telegram(cfg, msg))
    if cfg.start_delay:
        sleep(cfg.start_delay)
    snap = load_json(cfg.snapshot_file, {})
    sessions = snap.get("sessions", []) if isinstance(snap, dict) else []
    if not sessions:
        log("resume: empty snapshot, nothing to do")
        return {"revived": 0, "stale": 0, "cooldown": 0, "failed": 0}
    state = load_json(cfg.state_file, {})
    now = int(time.time() if now is None else now)

    try:
        tok = oauth_token(cfg)
    except Exception as e:  # noqa: BLE001
        log(f"resume: cannot read OAuth token from {cfg.cred_file}: {e}")
        notify(f"⚠️ claude-rc boot-resume: no OAuth token ({e}) — sessions not revived")
        return None
    try:
        env_id = current_env_id(cfg, tok, opener=opener)
    except Exception as e:  # noqa: BLE001
        log(f"resume: GET /v1/environments failed: {e}")
        notify(f"⚠️ claude-rc boot-resume: environment lookup failed ({e})")
        return None
    if not env_id:
        log(f"resume: no environment named '{cfg.device_name}:*' found — bridge not registered yet?")
        return None
    log(f"resume: environment={env_id} dry_run={cfg.dry_run} candidates={len(sessions)}")

    revived = skipped_stale = skipped_cooldown = failed = 0
    done = []
    for rec in sorted(sessions, key=lambda r: r.get("lastActive", 0), reverse=True):
        if revived >= cfg.max_revive:
            log(f"resume: hit MAX_REVIVE={cfg.max_revive}; "
                f"{len(sessions) - cfg.max_revive} not revived this run")
            break
        cse = rec.get("cseId")
        cwd = rec.get("cwd", "")
        if not cse:
            continue
        if now - int(rec.get("lastActive", 0)) > cfg.recency:
            skipped_stale += 1
            continue
        key = f"{cse}:{env_id}"
        if now - int(state.get(key, {}).get("revivedAt", 0)) < cfg.cooldown:
            skipped_cooldown += 1
            continue
        # NOTE: intentionally do NOT skip when the worktree is missing. A graceful
        # bridge stop deletes the worktree but keeps the session resumable, and the
        # bridge recreates the worktree from its branch on the reconnected work
        # poll. Reconnect is the right move either way; a dead session just fails.
        if cfg.dry_run:
            log(f"DRY-RUN: would reconnect {cse} (cwd={Path(cwd).name})")
            revived += 1
            done.append(cse)
            continue
        s, err = reconnect(cfg, tok, env_id, cse, opener=opener)
        if s in OK_STATUS:
            log(f"reconnect {cse[:12]} -> HTTP {s} OK")
            state[key] = {"cseId": cse, "revivedAt": now}
            revived += 1
            done.append(cse)
            if revived < cfg.max_revive:
                sleep(cfg.delay)
        else:
            log(f"reconnect {cse[:12]} -> HTTP {s} {err}")
            failed += 1

    save_json(cfg.state_file, state)
    summary = (f"{'[dry-run] ' if cfg.dry_run else ''}claude-rc boot-resume: "
               f"revived={revived} stale={skipped_stale} cooldown={skipped_cooldown} "
               f"failed={failed}")
    log(summary)
    if revived or failed:
        short = ", ".join(c[4:12] for c in done)
        notify(f"🔁 {summary}" + (f"\nrevived: {short}" if short else ""))
    return {"revived": revived, "stale": skipped_stale,
            "cooldown": skipped_cooldown, "failed": failed}


def main(argv=None, env=None):
    cfg = Config.from_env(env)
    argv = sys.argv[1:] if argv is None else argv
    cmd = argv[0] if argv else "resume"
    if cmd == "snapshot":
        cmd_snapshot(cfg)
        return 0
    if cmd == "resume":
        cmd_resume(cfg)
        return 0
    print(__doc__)
    return 2


if __name__ == "__main__":
    sys.exit(main())
