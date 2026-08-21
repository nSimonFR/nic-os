#!/usr/bin/env python3
"""
hermes-cron-check: does every no_agent job still point at a script that exists?

The job->script binding lives in Hermes-managed cron/jobs.json, which the repo
does not track, and the seeding rsync omits --delete. So renaming or deleting a
shim is a green rebuild plus a failing tick: the scheduler answers "Script not
found" at that job's next fire, which for a weekly job is up to seven days later.
This runs at hermes start and says so while someone is still watching the rebuild.

Prints one line per mismatch — empty output means every binding resolves — so the
caller can pipe it straight to a notifier. Never fails: an unreadable jobs.json
must not keep Hermes down.

Env: HERMES_HOME.
"""

import json
import os
import sys
from dataclasses import dataclass
from pathlib import Path

from ..logs import logger
from ..secrets import env_str

# stderr: stdout is the nudge.
log = logger("hermes-cron-check", lambda: sys.stderr)

DEFAULT_HOME = "~/.hermes"


@dataclass(frozen=True)
class Config:
    hermes_home: str = DEFAULT_HOME

    @classmethod
    def from_env(cls, env=None):
        return cls(
            hermes_home=os.path.expanduser(env_str("HERMES_HOME", DEFAULT_HOME, env))
        )


def unbound(jobs, scripts_dir):
    """(id, name, script) per no_agent job whose script is not a file in scripts_dir."""
    out = []
    for job in jobs:
        script = (job.get("script") or "").strip()
        if not job.get("no_agent") or not script:
            continue
        if not (scripts_dir / script).is_file():
            out.append((job.get("id", "?"), job.get("name", "?"), script))
    return out


def run(cfg, opener=open):
    home = Path(cfg.hermes_home)
    try:
        with opener(home / "cron" / "jobs.json") as fh:
            data = json.load(fh)
    except (OSError, ValueError) as e:
        log(f"cannot read jobs.json ({e}) — check skipped")
        return ""

    jobs = data if isinstance(data, list) else data.get("jobs", data)
    if isinstance(jobs, dict):
        jobs = list(jobs.values())

    missing = unbound(jobs, home / "scripts")
    if not missing:
        log(f"{sum(1 for j in jobs if j.get('no_agent'))} no_agent bindings all resolve")
        return ""

    return "\n".join(
        ["⚠️ Hermes cron — script introuvable, ces jobs échoueront :"]
        + [f"• {name} ({jid}) → {script}" for jid, name, script in missing]
    )


def main(argv=None, env=None):
    del argv
    message = run(Config.from_env(env))
    if message:
        print(message)
    return 0


if __name__ == "__main__":
    sys.exit(main())
