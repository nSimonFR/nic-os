#!/usr/bin/env python3
"""
hermes-mcp-token-check: will an OAuth MCP server drop out of Hermes soon?

Hermes refreshes OAuth tokens on its own, but T3 Code issues none: its MCP client
session lasts 30 days, then every mcp__t3__* tool vanishes from the agent with
nothing said in Telegram. This warns while there is still time to re-login.

Servers come from config.yaml entries with `auth: oauth` (the file is JSON, as
hermes.nix writes it), tokens from mcp-tokens/<server>.json, whose `expires_at`
Hermes stores as an absolute epoch. Empty stdout means nothing to do.

Env: HERMES_HOME, MCP_TOKEN_WARN_DAYS.
"""

import json
import os
import sys
import time
from dataclasses import dataclass
from pathlib import Path

from ..logs import logger
from ..secrets import env_int, env_str

# stderr: stdout is the delivered message.
log = logger("hermes-mcp-token-check", lambda: sys.stderr)

DEFAULT_HOME = "~/.hermes"


@dataclass(frozen=True)
class Config:
    hermes_home: str = DEFAULT_HOME
    warn_days: int = 5

    @classmethod
    def from_env(cls, env=None):
        return cls(
            hermes_home=os.path.expanduser(env_str("HERMES_HOME", DEFAULT_HOME, env)),
            warn_days=env_int("MCP_TOKEN_WARN_DAYS", 5, env),
        )


def _load(path, opener):
    try:
        with opener(path) as fh:
            return json.load(fh)
    except (OSError, ValueError):
        return None


def oauth_servers(config):
    servers = (config or {}).get("mcp_servers") or {}
    return sorted(name for name, entry in servers.items() if (entry or {}).get("auth") == "oauth")


def problem(tokens, now, warn_days):
    """Why this server needs a login, or None."""
    if not tokens or not tokens.get("access_token"):
        return "jamais connecté"
    if tokens.get("refresh_token"):
        return None
    expires_at = tokens.get("expires_at")
    if expires_at is None:
        return None
    days = (float(expires_at) - now) / 86400
    if days <= 0:
        return "expiré"
    if days <= warn_days:
        return f"expire dans {days:.0f} j" if days >= 1 else "expire aujourd'hui"
    return None


def run(cfg, opener=open, now=None):
    home = Path(cfg.hermes_home)
    config = _load(home / "config.yaml", opener)
    if config is None:
        log("cannot read config.yaml — check skipped")
        return ""
    now = time.time() if now is None else now

    issues = []
    for name in oauth_servers(config):
        why = problem(_load(home / "mcp-tokens" / f"{name}.json", opener), now, cfg.warn_days)
        log(f"{name}: {why or 'ok'}")
        if why:
            issues.append((name, why))
    if not issues:
        return ""

    return "\n".join(
        ["🔑 Hermes MCP — connexion OAuth à refaire :"]
        + [f"• {name} : {why} → hermes mcp login {name}" for name, why in issues]
    )


def main(argv=None, env=None):
    del argv
    message = run(Config.from_env(env))
    if message:
        print(message)
    return 0


if __name__ == "__main__":
    sys.exit(main())
