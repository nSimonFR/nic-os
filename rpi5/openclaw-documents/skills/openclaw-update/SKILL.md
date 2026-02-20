---
name: openclaw-update
description: Safely update OpenClaw config and skills via NixOS rebuild with optional backup. Use when the user wants to update OpenClaw, change skills, or back up the current config.
metadata: {"openclaw":{"emoji":"💾","requires":{"bins":["git"]},"tags":["backup","restore","update","nixos"]}}
---

# OpenClaw Update (NixOS)

Safe workflow for updating OpenClaw config and skills on this NixOS system.

## How It Works

On this system, all OpenClaw config is declaratively managed in `~/nic-os/rpi5/`.
Changes require editing `.nix` files and running `nixos-rebuild` — direct file edits are reverted.

NixOS generations provide automatic rollback, so every rebuild is inherently safe.

## Check Current State

```bash
# Confirm config source
readlink -f ~/.openclaw/openclaw.json

# Current generation
sudo nix-env --list-generations --profile /nix/var/nix/profiles/system | tail -5

# OpenClaw gateway status
systemctl --user status openclaw-gateway
```

## Before Making Changes (optional backup)

```bash
# Backup current nic-os config to a tarball
tar -czf ~/openclaw-backup-$(date +%Y%m%d-%H%M%S).tar.gz \
  ~/nic-os/rpi5/openclaw.nix \
  ~/nic-os/rpi5/openclaw-documents/

# Or just commit the current state
cd ~/nic-os
git add rpi5/openclaw.nix rpi5/openclaw-documents/
git commit --no-gpg-sign -m "backup openclaw config before update"
```

## Update Skills

Skills live in `~/nic-os/rpi5/openclaw-documents/skills/`.
To add or modify a skill, edit the SKILL.md file there, then rebuild:

```bash
cd ~/nic-os
sudo nixos-rebuild switch --flake 'path:.#rpi5'
```

## Update OpenClaw Config

Edit `~/nic-os/rpi5/openclaw.nix` then rebuild as above.

For a fast path (no rebuild needed for runtime config only):
1. Edit `~/nic-os/rpi5/openclaw.nix`
2. Also edit `~/.openclaw/openclaw.json` with the same change
3. Restart gateway: `systemctl --user restart openclaw-gateway`

**Keep both in sync — the .nix file is the source of truth for the next rebuild.**

## Rollback

NixOS keeps previous generations. To roll back:

```bash
# List generations
sudo nix-env --list-generations --profile /nix/var/nix/profiles/system

# Roll back to previous generation
sudo nixos-rebuild switch --rollback

# Or switch to specific generation
sudo nix-env --switch-generation <N> --profile /nix/var/nix/profiles/system
sudo systemctl daemon-reload
```

## Verify After Update

```bash
# Gateway running?
systemctl --user status openclaw-gateway

# Config loaded from correct path?
readlink -f ~/.openclaw/openclaw.json

# Skills deployed?
ls ~/.openclaw/workspace/skills/ 2>/dev/null || ls ~/.openclaw/skills/ 2>/dev/null
```
