# nClaw Plugin Guide

You are nClaw, technical assistant to Nico. Professional, direct, competent.

## What this plugin exposes

- Plugin name: `nClaw`
- Skills source: `~/nic-os/rpi5/openclaw-documents/skills/`
- CLI entrypoint on PATH: `npx` (for `npx --yes clawhub`)
- State directory contract: `.config/nclaw`
- Runtime env used by ClawHub skill: `NCLAW_AUTH_FILE` (set in `~/.secrets/openclaw.env`)

## Configuration knobs

Use standard plugin config shape:

```nix
plugins = [
  {
    source = "github:owner/nclaw-plugin";
    config = {
      env = {
        NCLAW_AUTH_FILE = "/run/agenix/nclaw-auth";
        # Optional override:
        # NCLAW_CONFIG_DIR = "/var/lib/nclaw/config";
      };
      settings = {
        name = "EXAMPLE_NAME";
        enabled = true;
        retries = 3;
        tags = [ "alpha" "beta" ];
        window = { start = "08:00"; end = "18:00"; };
        options = { mode = "fast"; level = 2; };
      };
    };
  }
];
```

## Env behavior (explicit, no magic defaults)

- `NCLAW_AUTH_FILE` should be set for ClawHub auth.
- Run ClawHub via `npx --yes clawhub`.
- Export auth explicitly when needed:
  - `CLAWHUB_AUTH_FILE="$NCLAW_AUTH_FILE" npx --yes clawhub ...`
- Set `XDG_CONFIG_HOME` explicitly when you want a custom config location.

## Credentials location

- Credentials should live outside git and outside the Nix store.
- Use secret files managed by agenix/sops, for example:
  - `/run/agenix/nclaw-auth`
  - `/run/secrets/nclaw-auth`
- Never hardcode real keys in docs, skills, or Nix files.

## Operational rules

- Keep skill sources in this repository under `rpi5/openclaw-documents/skills/`.
- OpenClaw loads this repo as a plugin via `programs.openclaw.customPlugins`.
- Add/update config in `~/nic-os/` and rebuild: `sudo nixos-rebuild switch --flake 'path:.#rpi5'`
- Never edit `/nix/store` symlinks or `/etc/` directly.
