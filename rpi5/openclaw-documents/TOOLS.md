# Tools & Conventions

## System Environment

- Operating System: NixOS Linux
- Shell: zsh
- Package Manager: Nix (with flakes)
- Configuration: Home-manager

## Local Tools

- `nix` - Package management and builds
- `home-manager` - User environment management
- `git` - Version control
- `systemctl --user` - User service management

## Conventions

- Configuration files are in `~/nic-os/`
- Secrets are stored in `~/.secrets/`
- **IMPORTANT**: After any ~/nic-os changes, rebuild system:
  ```bash
  sudo nixos-rebuild switch --flake 'path:.#rpi5'
  ```
- Changes won't apply without explicit rebuild

## Read-Only Filesystem Policy

- Files symlinked to `/nix/store/` are **immutable** — never write to them
- System config (`/etc/`), systemd units, and home-manager dotfiles are **managed by Nix** — never edit directly
- OpenClaw config, documents, and skills are deployed from `~/nic-os/rpi5/` — edit there, then rebuild
- `~/.openclaw/openclaw.json` is a **Nix-managed symlink** — never edit directly
- To check: `readlink -f <file>` — if it points to `/nix/store/`, it's managed
- **Only `~/.secrets/` and user-created non-symlinked files are writable**

## OpenClaw Configuration

### Architecture

- **Nix source of truth**: `~/nic-os/rpi5/openclaw.nix` — gateway config, models, channels, plugins
- **Documents & skills source**: `~/nic-os/rpi5/openclaw-documents/` — deployed to `~/.openclaw/workspace/`
- **Runtime config**: `~/.openclaw/openclaw.json` — Nix-managed symlink, DO NOT edit
- **Secrets/env vars**: `~/.secrets/openclaw.env` — loaded as `EnvironmentFile` by the gateway systemd service
- **Gateway service**: `openclaw-gateway` (user systemd unit)

### Skills

Skills live in `~/nic-os/rpi5/openclaw-documents/skills/<name>/SKILL.md`. The Nix config auto-discovers all subdirectories via `builtins.readDir`. Each SKILL.md has YAML frontmatter with optional `metadata.openclaw.requires`:

- `requires.bins` — binaries that must be in PATH
- `requires.env` — environment variables that must be set

If any requirement is unmet, OpenClaw hides the skill (shows as "missing" in `openclaw skills`).

**Environment variables for skills** must be set in `~/.secrets/openclaw.env` so the gateway process has them. They are NOT automatically available in interactive shells.

### Changing Config vs Changing Secrets

| Change | Where to edit | Then |
|--------|--------------|------|
| Models, channels, plugins, gateway settings | `~/nic-os/rpi5/openclaw.nix` | `sudo nixos-rebuild switch --flake 'path:~/nic-os#rpi5'` |
| Skill content or new skill | `~/nic-os/rpi5/openclaw-documents/skills/` | Rebuild |
| API keys, tokens, env vars for skills | `~/.secrets/openclaw.env` | `systemctl --user restart openclaw-gateway` |

### Useful Commands

- `openclaw skills` — list all skills and their status (ready/missing)
- `systemctl --user status openclaw-gateway` — check gateway health
- `systemctl --user restart openclaw-gateway` — apply env var changes without rebuild
- `journalctl --user -u openclaw-gateway -n 50 --no-pager` — gateway logs
- `journalctl --user -u home-manager-nsimon.service -n 50 --no-pager` — home-manager activation logs

## Notes

- Prefer editing existing Nix files over creating new ones
- Test changes with `nix build --dry-run` before applying
- If home-manager fails with "would be clobbered", delete the blocking file and rebuild
