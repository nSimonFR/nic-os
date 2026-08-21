"""Deterministic bodies for Hermes' `no_agent` cron jobs — zero tokens per tick.

The scheduler's contract (cron/scheduler.py, no_agent branch) shapes all of them:
non-empty stdout is delivered verbatim as the message, empty stdout is a silent
run, a non-zero exit is delivered as an error alert. So these log to **stderr**,
and one that sends its own richer message prints nothing on success.

Hermes also scrubs secret-shaped variables before spawning us, so credentials are
re-exported by the `*.sh` shim in hosts/rpi5/hermes/hermes.nix, not inherited.
"""

__all__ = ["calendar_digest", "dawarich_daily", "zen_watch"]
