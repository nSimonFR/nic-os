# Tools & Conventions

## System

- OS: NixOS | Shell: zsh | Package Manager: Nix (flakes)
- Config source: `~/nic-os/` → rebuild: `sudo nixos-rebuild switch --flake 'path:.#rpi5'`
- **Rule:** Never edit /nix/store symlinks or /etc/ directly. Use .nix files + rebuild.
- Secrets: `~/.secrets/` (writable)
- Skills: `~/nic-os/rpi5/openclaw-documents/skills/<name>/SKILL.md`

## OpenClaw Architecture

- **Config source:** `~/nic-os/rpi5/openclaw.nix` (gateway, models, channels, plugins)
- **Documents/skills:** `~/nic-os/rpi5/openclaw-documents/` → deployed to `~/.openclaw/workspace/`
- **Runtime config:** `~/.openclaw/openclaw.json` (Nix-managed symlink, read-only)
- **Env vars:** `~/.secrets/openclaw.env` (loaded by systemd service)
- **Gateway service:** `openclaw-gateway` (user systemd unit)

## Config Changes

| Change | Edit | Then |
|--------|------|------|
| Models, channels, plugins, gateway | `~/nic-os/rpi5/openclaw.nix` | Rebuild |
| Skill content | `~/nic-os/rpi5/openclaw-documents/skills/` | Rebuild |
| API keys, tokens, env vars | `~/.secrets/openclaw.env` | `systemctl --user restart openclaw-gateway` |

## Useful Commands

- `openclaw skills` — list skills (ready/missing)
- `systemctl --user status openclaw-gateway` — check health
- `journalctl --user -u openclaw-gateway -n 50 --no-pager` — logs
