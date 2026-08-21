"""Deterministic replacements for Hermes' LLM-driven cron jobs.

Every module here is the *whole* job: Hermes runs it in `no_agent` mode, so
there is no model in the loop and the tick costs zero tokens. The contract the
scheduler imposes (cron/scheduler.py `run_job`) is the reason these look the
way they do:

  * **stdout IS the message.** Non-empty trimmed stdout is delivered verbatim to
    the job's Telegram target. So a script that already sent its own richer
    message (dawarich, which needs HTML) must print *nothing* on success.
  * **empty stdout is a silent run.** "Nothing to report" is spelled `print
    nothing`, not "no changes this week" — that is what keeps a weekly watcher
    from becoming weekly noise.
  * **non-zero exit is delivered as an alert**, stderr included. So failures
    belong on stderr + a non-zero return, never on stdout.
  * **the environment is scrubbed.** `_sanitize_subprocess_env` strips
    Hermes-managed secrets before spawning us, so anything credential-shaped is
    re-exported by the `*.sh` shim in hosts/rpi5/hermes/hermes.nix (which
    sources /run/agenix/agent-env) rather than assumed to be inherited.

The usual nicos_scripts rules still apply: no import-time I/O, a frozen
`Config.from_env(env)` read in `main()`, and an injectable seam on every call
that touches the network or a subprocess.
"""

__all__ = [
    "calendar_digest",
    "dawarich_daily",
    "zen_watch",
]
