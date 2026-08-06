"""Connector entry points (`project.scripts` in pyproject.toml).

Each module here exposes:
  * a frozen `Config` with a `from_env(env)` classmethod — nothing is read from
    the environment at import time;
  * pure payload-building functions taking their config explicitly, so the
    interesting logic (cursors, deltas, dedup) is testable with no I/O at all;
  * `main(env=None, opener=None) -> int` returning the process exit code.
"""
