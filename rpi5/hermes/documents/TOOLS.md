# Tools & Conventions

## System

- OS: NixOS | Shell: zsh | Package Manager: Nix (flakes)
- Config source: `~/nic-os/` → rebuild: `sudo nixos-rebuild switch --flake 'path:.#rpi5' --max-jobs 1 -j 1`
- **Rule:** Never edit /nix/store symlinks or /etc/ directly. Use .nix files + rebuild.
- Secrets: agenix — `/run/agenix/picoclaw-env` (read-only, system-managed)
- Skills: `~/nic-os/rpi5/picoclaw/skills/<name>/SKILL.md` (rsync'd to `~/.picoclaw/workspace/skills/`)

## PicoClaw Architecture

- **Config source:** `~/nic-os/rpi5/picoclaw/picoclaw.nix` (gateway, models, channels, tools)
- **Documents/skills:** `~/nic-os/rpi5/picoclaw/` → deployed to `~/.picoclaw/workspace/`
- **Runtime config:** `~/.picoclaw/config.json` (Nix-generated, overwritten on rebuild)
- **Env vars:** `/run/agenix/picoclaw-env` (loaded by systemd service EnvironmentFile)
- **Gateway service:** `picoclaw` (user systemd unit)
- **Models:** PicoClaw points at LiteLLM (`http://127.0.0.1:4001/v1`). Fallback chain (gpt-5.4 → gemma4) is configured in `rpi5/litellm.nix`, not here.

## Config Changes

| Change | Edit | Then |
|--------|------|------|
| Models, channels, tools, gateway | `~/nic-os/rpi5/picoclaw/picoclaw.nix` | Rebuild |
| Model fallback / routing | `~/nic-os/rpi5/litellm.nix` | Rebuild |
| Skill content | `~/nic-os/rpi5/picoclaw/skills/` | Rebuild |
| API keys, tokens | Re-encrypt `rpi5/secrets/picoclaw-env.age` | Rebuild |

## Useful Commands

- `systemctl --user status picoclaw` — check health
- `journalctl --user -u picoclaw -n 50 --no-pager` — logs
- `curl http://127.0.0.1:18789/health` — gateway health endpoint
- `cat ~/.picoclaw/config.json | jq` — inspect generated config
