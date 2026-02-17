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
- Use `home-manager switch --flake '.#BeAsT'` to apply config changes

## Notes
- Prefer editing existing Nix files over creating new ones
- Test changes with `nix build --dry-run` before applying
