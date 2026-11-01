# 0009 — rpi5 modules are grouped by domain

**Date:** 2026-11-01 · **Status:** Accepted

## Context

`hosts/rpi5/` held ~70 `.nix` files side by side, and `configuration.nix` imported
each one by hand in an order nobody chose. Finding "everything about money" or
"everything an agent can touch" meant reading the whole list. The 2026-08-06 host
rename also left a stale `rpi5/` copy at the repo root that kept receiving commits
(see the PR that introduced this ADR).

## Decision

Each module lives in a domain directory whose `default.nix` imports it;
`configuration.nix` imports the directories, not the files.

| Dir | Holds |
|---|---|
| `platform/` | databases, backups, deploys, alerting, beast's power |
| `network/` | Tailscale Serve, the 443 mux, DNS, homepage, tailnet MITM |
| `security/` | the eval-time policy, root access, agent credentials, Vaultwarden |
| `agents/` | Hermes (`hermes/`), Claude Code (`claude/`), Cyrus, T3, the LLM gate, Entire |
| `finance/` | Sure, Wealthfolio, the Sumeria capture |
| `media/` | Immich, Ryot |
| `knowledge/` | documents, notes, mail, calendars, search |
| `life/` | personal trackers and small automations |
| `home-assistant/` | Home Assistant and its dashboards |

Unchanged at the top: `configuration.nix`, `home.nix`, `overlays.nix`,
`secrets.nix` + `secrets/`, `lib/` (module helpers), `scripts/` (shell +
`nicos-scripts`).

Home-manager modules (`agents/hermes/hermes.nix`, `agents/entire-brain.nix`,
`knowledge/mail.nix`) sit in their domain too but are imported from `home.nix`,
never from a `default.nix`.

## Consequences

- New service: `hosts/rpi5/<domain>/<name>.nix` + one line in that `default.nix`.
  A service that fits no domain is the signal to add one, not to use the top level.
- Imports are explicit, not `readDir`-discovered: a stray file must not become
  live config by existing.
