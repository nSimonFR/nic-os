---
name: hermes-handoff
description: Hand a task to the Hermes agent on rpi5 — its own skills, memory and home network. Use when asked to hand off / delegate to Hermes, to add or change one of its cron jobs, or for a task needing its skills (Dawarich, Immich, Home Assistant, Ryot, firefly).
metadata:
  short-description: Delegate a task to rpi5's Hermes over ssh
---

# Hermes handoff

```bash
ssh rpi5 'set -a; . /run/agenix/agent-env; set +a; cd ~; hermes -c mac-handoff -z "$(cat)"' <<'EOF'
check dawarich ingested yesterday's points, fix it if not
EOF
```

Two halves of that line are not decoration. The prompt travels on **stdin**,
because an ssh command line is re-parsed by the login shell over there and any
quote, `$` or backtick in an argument would be re-interpreted. `agent-env` is
what gives Hermes' skills their credentials — without it they fail halfway.

`-c NAME` continues a session (same name = same thread), `-m gpt-6` buys a harder
model, `-s <skill>` preloads one. Slow task? Run it as a background Bash task,
and pipe the answer into `telegram-send` if Nico has left the keyboard.

## Notes

- `HTTP 429: usage limit has been reached` is the gate's plan cap, not a broken
  handoff.
- **Cron**: Hermes owns its jobs (`hermes cron list|create|edit`) in
  Hermes-managed `cron/jobs.json`, so a job it invents is NOT reproducible. One
  meant to last belongs in `hosts/rpi5/hermes/cron-scripts/` (seeded into
  `~/.hermes/scripts/`, bound `--script <name>.sh --no-agent`, which also spends
  no tokens per tick).
- Interactive instead: `ssh -t rpi5 'cd ~ && hermes chat'`. Never run
  `hermes gateway run` by hand — that's `hermes.service`'s job.
