# 0008 — Modules branch on host capabilities, not on host names

**Date:** 2026-08-06 · **Status:** Accepted

## Context

`hostname` was a specialArg on all three system configs and had exactly one
consumer in the tree (`hosts/nbookpro/configuration.nix`). Both NixOS hosts swallowed it
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
  That was not cosmetic: `beastHost` was consumed by `hosts/beast/immich-ml.nix` but
  never passed to BeAsT, and only avoided being an eval failure because the sole
  reference sat inside a `#` comment, where Nix does not interpolate.
- **The directories are named after the hosts**: `nixos/` → `hosts/beast/`,
  `rpi5/` → `hosts/rpi5/`, `macos/` → `hosts/nbookpro/`. Three targets previously
  used three different naming schemes, none of them the host's name, and one of
  them (`nixos/`) named the operating system that *both* Linux hosts run while
  containing only BeAsT's config.

  The rename is mechanical and carries no behaviour, so it is a separate commit
  from everything above; keeping the two apart is what makes the rest reviewable.

  One thing in it is load-bearing rather than cosmetic and is easy to miss:
  `hosts/rpi5/hermes/documents/TOOLS.md` is a **live agent document** whose
  `~/nic-os/rpi5/...` paths the agent actually follows. Moving the directory
  without rewriting them points a running agent at nothing.

  A second such trap existed while this branch was open and no longer does: the
  Git LFS rule in `.gitattributes` matched a literal path, so the move silently
  un-tracked `wallpaper.png`. `main` then reverted LFS entirely (see that
  commit's message — a `github:` flake ref is fetched as a tarball, and tarballs
  don't expand pointers, which broke the README's own documented install path).
  `.gitattributes` is gone and the wallpaper is a plain 13 MB blob that moves
  with its directory like any other file.

  Path references in prose were rewritten only where the rewritten path exists in
  the tree. ADRs 0001–0003 describe directories deleted long ago
  (`hosts/rpi5/picoclaw/`, `hosts/rpi5/openclaw/`) — those never lived under `hosts/`, and
  rewriting them would invent a path that never existed.
- `common/nixos.nix` now holds the baseline the two NixOS hosts share. macOS
  deliberately does not import it — nix-darwin's option set only partly overlaps
  NixOS's, so the shared-*looking* options mean different things or don't exist.
  This follows `shared/tailscale.nix`: shared by the hosts that can share it.
