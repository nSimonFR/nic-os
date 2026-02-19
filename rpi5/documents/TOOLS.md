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
- To check: `readlink -f <file>` — if it points to `/nix/store/`, it's managed
- **Only `~/.secrets/` and user-created non-symlinked files are writable**

## Notes
- Prefer editing existing Nix files over creating new ones
- Test changes with `nix build --dry-run` before applying
