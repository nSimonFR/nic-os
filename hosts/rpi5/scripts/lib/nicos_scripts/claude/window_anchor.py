#!/usr/bin/env python3
"""claude-window-anchor — start acct1's 5h usage window at a fixed time of day.

A 5h window opens on the first request after the previous one expired, so left
alone its phase is wherever the day's first message landed. Fired at each anchor
(07:00 / 12:00 / 17:00), this reads the current window from the usage endpoint
(free — reading it opens nothing) and:

  * no open window      -> ping now, the window starts at the anchor;
  * a window still open -> sleep until it resets, then ping, so the next one
                           starts back to back instead of at the next message.

A ping whose time falls outside [DAY_START, DAY_END) is skipped: a window opened
at night would still be open at the 07:00 anchor and push the whole day back.

The ping must reach Anthropic, so it names a Claude model, never an asale-* id.

Config via environment:
  ANCHOR_TOKEN_FILE   OAuth access token     (default /run/claude-oauth/token)
  ANCHOR_USAGE_URL    usage endpoint
  ANCHOR_CLAUDE       claude binary          (default claude)
  ANCHOR_MODEL        ping model             (default sonnet)
  ANCHOR_DAY_START    earliest ping, HH:MM   (default 07:00)
  ANCHOR_DAY_END      latest ping, HH:MM     (default 20:00)
  ANCHOR_SLACK        seconds after a reset before pinging (default 60)
  ANCHOR_DRY_RUN      "0" to actually ping   (default dry run)
"""

import subprocess
import sys
import time
from dataclasses import dataclass
from datetime import datetime, time as dtime, timedelta
from pathlib import Path

from ..httpjson import get_json
from ..logs import logger
from ..secrets import env_int, env_str

DEFAULT_USAGE_URL = "https://api.anthropic.com/api/oauth/usage"

log = logger("claude-window-anchor")


def _hhmm(raw, default):
    try:
        h, m = raw.split(":")
        return dtime(int(h), int(m))
    except (ValueError, AttributeError):
        return default


@dataclass(frozen=True)
class Config:
    token_file: Path = Path("/run/claude-oauth/token")
    usage_url: str = DEFAULT_USAGE_URL
    claude: str = "claude"
    model: str = "sonnet"
    day_start: dtime = dtime(7, 0)
    day_end: dtime = dtime(20, 0)
    slack: int = 60
    dry_run: bool = True

    @classmethod
    def from_env(cls, env=None):
        d = cls()
        return cls(
            token_file=Path(env_str("ANCHOR_TOKEN_FILE", "", env) or d.token_file),
            usage_url=env_str("ANCHOR_USAGE_URL", "", env) or d.usage_url,
            claude=env_str("ANCHOR_CLAUDE", "", env) or d.claude,
            model=env_str("ANCHOR_MODEL", "", env) or d.model,
            day_start=_hhmm(env_str("ANCHOR_DAY_START", "", env), d.day_start),
            day_end=_hhmm(env_str("ANCHOR_DAY_END", "", env), d.day_end),
            slack=env_int("ANCHOR_SLACK", d.slack, env),
            dry_run=env_str("ANCHOR_DRY_RUN", "1", env) != "0",
        )


class UsageUnavailable(Exception):
    pass


def fetch_reset(cfg, opener=None):
    """-> aware datetime the open window resets at, or None when none is open."""
    try:
        token = cfg.token_file.read_text().strip()
        usage = get_json(
            cfg.usage_url,
            headers={
                "Authorization": f"Bearer {token}",
                "anthropic-beta": "oauth-2025-04-20",
                "User-Agent": "nicos-claude-window-anchor",
            },
            timeout=15,
            opener=opener,
        )
    except Exception as e:  # noqa: BLE001 — any failure means "can't tell"
        raise UsageUnavailable(str(e)) from e
    raw = (usage.get("five_hour") or {}).get("resets_at")
    if not raw:
        return None
    try:
        return datetime.fromisoformat(raw)
    except ValueError as e:
        raise UsageUnavailable(f"bad resets_at {raw!r}") from e


def plan(cfg, now, reset):
    """-> (ping_at, reason). ping_at is None when the ping should be skipped."""
    if reset is None or reset <= now:
        at, why = now, "no open window"
    else:
        at = reset + timedelta(seconds=cfg.slack)
        why = f"window open until {reset.astimezone(now.tzinfo):%H:%M}"
    local = at.astimezone(now.tzinfo).time()
    if not cfg.day_start <= local < cfg.day_end:
        return None, f"{why}; {local:%H:%M} is outside {cfg.day_start:%H:%M}-{cfg.day_end:%H:%M}"
    return at, why


def ping(cfg, run=None, log=log):
    """One minimal request. Returns True on a zero exit (or in a dry run)."""
    argv = [
        cfg.claude, "-p", "hi", "--model", cfg.model,
        "--setting-sources", "", "--strict-mcp-config", "--tools", "",
    ]
    if cfg.dry_run:
        log(f"DRY RUN — would run {' '.join(argv)}")
        return True
    try:
        res = (run or subprocess.run)(argv, capture_output=True, text=True, timeout=180)
    except Exception as e:  # noqa: BLE001
        log(f"ping failed: {e}")
        return False
    if res.returncode != 0:
        log(f"ping exited {res.returncode}: {(res.stdout + res.stderr).strip()[:300]}")
    return res.returncode == 0


def main(env=None, clock=None, opener=None, run=None, sleep=time.sleep, log=log):
    cfg = Config.from_env(env)
    now = (clock or (lambda: datetime.now().astimezone()))()
    try:
        reset = fetch_reset(cfg, opener=opener)
    except UsageUnavailable as e:
        # Pinging into an open window moves nothing, so not knowing is no reason to skip.
        log(f"usage unavailable ({e}) — pinging blind")
        reset = None

    at, why = plan(cfg, now, reset)
    if at is None:
        log(f"skip: {why}")
        return 0
    wait = (at - now).total_seconds()
    if wait > 0:
        log(f"{why} — pinging at {at.astimezone(now.tzinfo):%H:%M:%S}")
        if cfg.dry_run:
            return 0
        sleep(wait)
    else:
        log(f"{why} — pinging now")

    if not ping(cfg, run=run, log=log):
        return 1
    if cfg.dry_run:
        return 0
    try:
        after = fetch_reset(cfg, opener=opener)
    except UsageUnavailable as e:
        log(f"pinged; could not confirm the new window ({e})")
        return 0
    if after is None:
        log("pinged but no window is open — did the request reach Anthropic?")
        return 1
    log(f"window open, resets at {after.astimezone(now.tzinfo):%H:%M}")
    return 0


if __name__ == "__main__":
    sys.exit(main())
