# `pkgs/` — package definitions

Every derivation this repo builds itself lives here. A file in `pkgs/` answers
*how is this thing built*; the matching module under `rpi5/` or `nixos/` answers
*how is it run* (users, units, ports, secrets, Serve entries).

`showmycards` is the reference split: `pkgs/showmycards.nix` builds the Go
backend + SvelteKit frontend, `rpi5/showmycards.nix` is purely the service
module.

## The two ways a package reaches its consumer

**`callPackage` — one consumer.** The default. The service module says
`pkgs.callPackage ../pkgs/<name>.nix { }` at its single use site. Nothing is
added to any host's `pkgs`.

**Overlay — two or more consumers.** `pkgs/overlay.nix` exposes the package as
`pkgs.<name>`, so every consumer resolves the same store path from one
evaluation. Applied by `rpi5/overlays.nix`, `nixos/overlays.nix` and the
`homeConfigurations` in `flake.nix`, all via `outputs.overlays.nic-os`.

Move a package from the first form to the second the moment a second consumer
appears — that, not "is it important", is the rule. `mtg-mcp` was `callPackage`d
independently from two places (Hermes and the `claude-mtg` CLI), which evaluated
it twice with no single source of truth; it is an overlay entry now.

## Platforms

`pkgs/` is flat and global; entries are lazy, so a package no host references
costs nothing. Several are single-platform in practice — `tobii/*`,
`openrgb-lg`, `graillon-free`, `lg-sphere-ambient` are BeAsT (x86) only;
`showmycards` and `ble-scale-sync` are built on the rpi5 (aarch64). Where
upstream declares it, that constraint is in the derivation's `meta.platforms`.

## Verifying a move

Moving a derivation should not change what gets built. The check is store-path
equality:

```sh
nix eval --raw '.#nixosConfigurations.rpi5.config.system.build.toplevel.drvPath'
nix eval --raw '.#nixosConfigurations.BeAsT.config.system.build.toplevel.drvPath'
```

Run before and after. Identical output = provably a no-op. If a path changes,
the move altered the build — most often by re-indenting an `''` string, since
Nix strips the *minimum* indentation across the whole string, so a block that
already contains a column-0 line (a heredoc body, say) is not safe to shift.
`pkgs/tobii/opentrack-sc.nix` carries a note where that applies.

On the rpi5, `earlyoom` will kill a full evaluation under memory pressure
("interrupted by the user"); retry rather than assume a failure.

## Not (yet) here

The nixos-raspberrypi bootloader chain in `rpi5/configuration.nix` — five
derivations that patch an *input flake's* source. It is the largest inline build
left and the one most likely to brick a boot if botched, so it is deliberately a
separate decision.
