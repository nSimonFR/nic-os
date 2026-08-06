# 0002 — PicoClaw retired, Hermes is the sole Telegram agent

**Date:** 2026-07-24 · **Status:** Accepted · Supersedes [0001](0001-openclaw-retired.md)
**Commit:** `b387a63` *refactor(agents): retire PicoClaw, Hermes is the sole Telegram agent*

## Context

PicoClaw and Hermes ran side by side as an A/B. Hermes won. PicoClaw was a tiny
Go runtime (<20 MB resident) reaching models through LiteLLM on `:4001`; Hermes
is a Python+Node runtime (hundreds of MB, hence `MemoryMax=1G`) reaching them
through Aperture.

## Decision

`hosts/rpi5/picoclaw/` deleted. The shared cross-agent skills, the agent-local skills,
the persona documents and the `agent-env` agenix secret all moved to
`hosts/rpi5/hermes/`.

## Consequences

Everything a reader might reach for moved at once:

| Was | Is now |
|---|---|
| `rpi5/picoclaw/picoclaw.nix` | `hosts/rpi5/hermes/hermes.nix` |
| `rpi5/picoclaw/skills/` | `shared/skills/` + `hosts/rpi5/hermes/skills/` |
| `~/.picoclaw/config.json` | `~/.hermes/config.yaml` |
| `~/.picoclaw/workspace/` | `~/.hermes/` and `~/.hermes/workspace/` |
| `systemctl --user status picoclaw` | `systemctl --user status hermes` |
| routing in `hosts/rpi5/litellm.nix` | inline in `hosts/rpi5/hermes/hermes.nix` |
| gateway health on `:18789` | none — Hermes polls Telegram, no HTTP surface |

Two deliberate naming inconsistencies remain, both documented in place rather
than renamed, because renaming either means re-encrypting a secret or breaking a
runtime path:

- the agenix secret is still `agent-env` (was `picoclaw-env`)
- `pkgs.rtk` and the PATH construction in `hermes.nix` still mention picoclaw
  as the origin of the PATH shape

Residue cleaned up on 2026-08-06: `hosts/rpi5/hermes/documents/TOOLS.md` was a **live**
agent document — rsync'd into `~/.hermes/` on every service restart — in which
every single path still pointed at the deleted PicoClaw layout. `IDENTITY.md`
still claimed Hermes was "Created: Nix PicoClaw home-manager module".

The lesson worth keeping: **the persona documents under `hosts/rpi5/hermes/documents/`
are deployed, not archived.** A stale path in them is a live defect, because the
agent reads them as instructions.
