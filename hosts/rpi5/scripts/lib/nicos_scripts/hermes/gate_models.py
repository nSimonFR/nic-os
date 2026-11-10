#!/usr/bin/env python3
"""
hermes-gate-models: fill Hermes' /model list from tiny-llm-gate's catalog.

Runs at hermes start, after config.yaml is written. The picker lives in the
gate (`codex_catalog`, patterns over discovered models), so a model the gate
starts serving shows up here on the next restart, without a rebuild.

Never fails: when the gate is unreachable the Nix-baked list stays. The gate
discovers upstreams a few seconds after it starts, so an empty catalog is
retried until WAIT_SECONDS.

Env: HERMES_CONFIG, GATE_CATALOG_URL, HERMES_PROVIDER, CONTEXT_LENGTH, WAIT_SECONDS.
"""

import json
import os
import sys
import time
from dataclasses import dataclass
from pathlib import Path

from ..httpjson import get_json
from ..logs import logger
from ..secrets import env_int, env_str

log = logger("hermes-gate-models", lambda: sys.stderr)


@dataclass(frozen=True)
class Config:
    hermes_config: str = "~/.hermes/config.yaml"
    catalog_url: str = "http://127.0.0.1:4001/codex/models?client_version=1.0.0"
    provider: str = "tiny-llm-gate"
    # Hermes refuses a model under 64k; 131072 is what it has run on here.
    context_length: int = 131072
    wait_seconds: int = 30

    @classmethod
    def from_env(cls, env=None):
        return cls(
            hermes_config=os.path.expanduser(
                env_str("HERMES_CONFIG", cls.hermes_config, env)
            ),
            catalog_url=env_str("GATE_CATALOG_URL", cls.catalog_url, env),
            provider=env_str("HERMES_PROVIDER", cls.provider, env),
            context_length=env_int("CONTEXT_LENGTH", cls.context_length, env),
            wait_seconds=env_int("WAIT_SECONDS", cls.wait_seconds, env),
        )


def fetch_ids(cfg, opener=None, sleep=time.sleep, clock=time.monotonic):
    """Catalog slugs in picker order; [] when the gate never answers in time."""
    deadline = clock() + cfg.wait_seconds
    while True:
        try:
            body = get_json(cfg.catalog_url, timeout=10, opener=opener)
            ids = [m["slug"] for m in body.get("models", []) if m.get("slug")]
            if ids:
                return ids
            err = "empty catalog"
        except (OSError, ValueError) as e:
            err = str(e)
        if clock() >= deadline:
            log(f"gate catalog unavailable ({err}); keeping the baked list")
            return []
        sleep(2)


def apply(config, ids, provider, context_length):
    """Replace that custom provider's models with `ids`; the default stays listed."""
    for p in config.get("custom_providers", []):
        if p.get("name") != provider:
            continue
        default = p.get("model")
        names = ids + ([default] if default and default not in ids else [])
        p["models"] = {n: {"context_length": context_length} for n in names}
        return True
    return False


def run(cfg, opener=None, sleep=time.sleep, clock=time.monotonic):
    ids = fetch_ids(cfg, opener=opener, sleep=sleep, clock=clock)
    if not ids:
        return 0
    path = Path(cfg.hermes_config)
    config = json.loads(path.read_text())
    if not apply(config, ids, cfg.provider, cfg.context_length):
        log(f"no custom provider {cfg.provider!r} in {path}; nothing to do")
        return 0
    tmp = path.with_suffix(".tmp")
    tmp.write_text(json.dumps(config, indent=2))
    os.chmod(tmp, 0o600)
    tmp.replace(path)
    log(f"{len(ids)} models from the gate catalog")
    return 0


def main(argv=None, env=None):
    del argv
    try:
        return run(Config.from_env(env))
    except (OSError, ValueError) as e:
        log(f"skipped: {e}")
        return 0


if __name__ == "__main__":
    sys.exit(main())
