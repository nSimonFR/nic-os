# Tools & Conventions

## System

- OS: NixOS | Shell: zsh | Package Manager: Nix (flakes)
- Config source: `~/nic-os/` → rebuild: `sudo nixos-rebuild switch --flake 'path:.#rpi5' --max-jobs 1 -j 1`
- **Rule:** Never edit /nix/store symlinks or /etc/ directly. Use .nix files + rebuild.
- Secrets: agenix — `/run/agenix/` (read-only, system-managed). Skill/tool creds
  live in `/run/agenix/agent-env`, sourced into the service environment.

## Hermes Architecture

Hermes is the sole agent on this host (it succeeded PicoClaw, retired 2026-07).
It runs as an `nsimon` **user** systemd unit polling the Telegram bot; there is
no HTTP gateway to curl.

- **Config source:** `~/nic-os/rpi5/hermes/hermes.nix` — a home-manager module.
  Everything below (model, skills, documents, cron workspace, MCP servers) is
  generated from it.
- **Runtime home (`$HERMES_HOME`):** `~/.hermes/`
  - `config.yaml` — Nix-generated, **overwritten on every restart**
  - `.env` — bot token + sender allowlist, written 0600 at start from
    `/run/agenix/telegram-bot-token`
  - `skills/` — deployed skills (see below)
  - `*.md` — these persona documents
  - `workspace/` — cron scripts (tracked) + live state (kanban.db, sandboxes)
  - `cron/jobs.json` — cron jobs; **runtime state, not Nix-managed**
- **Skills** deploy into `~/.hermes/skills/` from three sources:
  - `~/nic-os/shared/skills/<name>/SKILL.md` — shared across every agent
  - `~/nic-os/rpi5/hermes/skills/<name>/SKILL.md` — Hermes-local
  - `~/nic-os/shared/mtg-skills/` → `~/.hermes/skills/mtg/` (MTG surfaces only)
- **Models / routing:** configured inline in `hermes.nix`. Hermes points at
  **Aperture** (`http://ai.gate-mintaka.ts.net/v1`), which forwards to
  tiny-llm-gate so usage and cost land on the observability dashboard. Current
  model: `gpt-5.6-terra`. **No Anthropic fallback** — deliberately; see the long
  note in `hermes.nix`, do not re-add one.

## Config Changes

| Change | Edit | Then |
|--------|------|------|
| Model, routing, MCP servers, memory | `~/nic-os/rpi5/hermes/hermes.nix` | Rebuild |
| Shared skill content | `~/nic-os/shared/skills/<name>/SKILL.md` | Rebuild |
| Hermes-only skill content | `~/nic-os/rpi5/hermes/skills/<name>/SKILL.md` | Rebuild |
| Persona / these docs | `~/nic-os/rpi5/hermes/documents/` | Rebuild |
| Cron helper scripts | `~/nic-os/rpi5/hermes/workspace/` | Rebuild |
| API keys, tokens | Re-encrypt `rpi5/secrets/agent-env.age` | Rebuild |
| Cron jobs themselves | `~/.hermes/cron/jobs.json` (runtime) | No rebuild |

**Deploy caveat:** the rsyncs in `hermes.nix` omit `--delete`, so a file removed
from the repo lingers in `~/.hermes/` until cleaned by hand.

**Cron caveat:** pin `model` and `provider` per job in `jobs.json` — an
unpinned job is silently skipped when the configured model drifts.

## Useful Commands

- `systemctl --user status hermes` — check health
- `journalctl --user -u hermes -n 50 --no-pager` — logs
- `systemctl --user restart hermes` — reload config.yaml + redeploy skills/docs
- `cat ~/.hermes/config.yaml` — inspect generated config
- `cat ~/.hermes/cron/ticker_last_success` — confirm the cron ticker is alive
- `systemctl --user list-timers` — hermes-skill-promote (hourly),
  weekly-tabletop-events (Mon 09:00 Europe/Paris)
