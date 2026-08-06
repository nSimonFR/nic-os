# 0001 — OpenClaw retired in favour of PicoClaw

**Date:** 2026-04-20 · **Status:** Superseded by [0002](0002-picoclaw-retired.md)
**Commit:** `4bd4434` *feat: migrate from OpenClaw to PicoClaw*

## Context

OpenClaw was the first Telegram agent on the rpi5. It lived at
`rpi5/openclaw/openclaw.nix`, generated `~/.openclaw/openclaw.json`, deployed
skills and persona documents into `~/.openclaw/workspace/`, and ran as the
`openclaw-gateway` user unit. Three of its plugins (`summarize`, `gogcli`,
`goplaces`) needed wrapper flakes purely to work around a Nix 2.31.2 `?dir=`
narHash crash.

## Decision

Replaced wholesale by PicoClaw. `rpi5/openclaw/` was deleted.

## Consequences

The runtime tree, the config path, the service name and the skill directory all
moved. Nothing named `openclaw` is live on any host.

Residue that outlived the deletion by two agent generations, all cleaned up on
2026-08-06:

- `.cursor/rules/openclaw-config.mdc` — 35 lines of "critical rules" for a
  deleted directory, still being fed to editors as authoritative
- `skills-lock.json` — a one-entry OpenClaw skills-registry lockfile, read by
  nothing
- `home/packages.nix` — `lib.lowPrio` on `nodejs_22` and `python312`, with
  comments citing "conflict with openclaw's bundled python"
- `rpi5/configuration.nix` — an authorized SSH key labelled `nsimon@rpi5-openclaw`

**Do not resurrect.** OpenClaw's SKILL.md format is the ancestor of the format
Hermes still uses, which is the only reason its name survives in comments.
