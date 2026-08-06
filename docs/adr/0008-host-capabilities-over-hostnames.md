# 0008 — Modules branch on host capabilities, not on host names

**Date:** 2026-08-06 · **Status:** Accepted

## Context

`hostname` was a specialArg on all three system configs and had exactly one
consumer in the tree (`macos/configuration.nix`). Both NixOS hosts swallowed it
in `...` and hardcoded their own name into `networking.hostName` instead. It
reached none of the four `extraSpecialArgs` blocks, so no module under `home/` —
imported by every host — could tell BeAsT from the rpi5. `pkgs.stdenv.isDarwin`
was the only discriminator available, and it cannot separate two Linux hosts.

The result was one module set pretending three very different machines were the
same machine: Star Citizen launcher config and two Wine-prefix symlinks on a
headless Pi and a Mac; VS Code, Zed and a `cursor --install-extension` activation
on a 3.9 GB headless server; a Bitwarden *desktop* SSH agent socket configured on
a host that doesn't run the desktop app; and an rpi5-specific 16K-page ripgrep
workaround applied to all three.

`home/claude.nix` did gate one entry on `isDarwin` — and even that didn't work:
the same `home.file` key was also set unconditionally in the base attrset, and
`//` takes the right operand, so on Linux the ungated definition simply survived.

## Decision

Host identity reaches every config — system *and* home-manager — and modules
branch on **what a host can do**, not on what it is called.

`flake.nix` holds one `hosts` attrset, one row per target, carrying the host's
name and a small capability set (`isGraphical`, `runsStarCitizen`,
`has16KPages`). It is passed as the `host` specialArg alongside `hostname`.
A module writes `lib.mkIf host.isGraphical`, never `hostname == "BeAsT"`.

Considered and rejected: passing `hostname` alone and comparing strings at each
site. It works, and it is one fewer concept — but it scatters the definition of
"BeAsT-ness" across five modules, so a fourth host means auditing every string
compare rather than adding a row. The capability name also carries the reason:
`isGraphical` explains why the Bitwarden socket is gated in a way that
`!= "rpi5"` does not.

The capability set is deliberately small and concrete. Capabilities are added
when a second consumer wants one, not speculatively.

## Consequences

- Adding a host is adding a row to `hosts` in `flake.nix`. A missing capability
  is an eval error at that row, not silent wrong behaviour on the new host.
- The seven hand-spelled specialArgs tuples collapsed to one `baseArgs` helper.
  That was not cosmetic: `beastHost` was consumed by `nixos/immich-ml.nix` but
  never passed to BeAsT, and only avoided being an eval failure because the sole
  reference sat inside a `#` comment, where Nix does not interpolate.
- **Not done here: the directory rename** (`nixos/` → `hosts/beast/` etc.). It is
  separable from the substance, touches every path in `flake.nix`, `README.md`
  and `.cursor/rules/`, and delivers none of the behaviour above. If it is ever
  wanted it should be its own change, reviewed on its own merits.
- `common/nixos.nix` now holds the baseline the two NixOS hosts share. macOS
  deliberately does not import it — nix-darwin's option set only partly overlaps
  NixOS's, so the shared-*looking* options mean different things or don't exist.
  This follows `shared/tailscale.nix`: shared by the hosts that can share it.
