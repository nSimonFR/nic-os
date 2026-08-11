# `pkgs/` — package definitions

Every derivation this repo builds itself lives here. A file in `pkgs/` answers
*how is this thing built*; the matching module under `hosts/rpi5/` or
`hosts/beast/` answers
*how is it run* (users, units, ports, secrets, Serve entries).

`showmycards` is the reference split: `pkgs/services/showmycards.nix` builds the Go
backend + SvelteKit frontend, `hosts/rpi5/showmycards.nix` is purely the service
module.

## Layout

Grouped by **domain**, not by host — a package that gains a second consumer
doesn't have to move, and related derivations sit together.

| folder | what goes in it |
|---|---|
| `agents/` | LLM and agent tooling — MCP servers, model lists, `rtk` |
| `cli/` | terminal tools installed into a user profile |
| `desktop/` | GUI apps and plugins (BeAsT) |
| `home-assistant/` | HA custom components and bridges |
| `rgb/` | OpenRGB / Hyperion / monitor lighting (BeAsT) |
| `services/` | daemons and web apps with a systemd unit behind them — including `nicos-scripts`, this repo's own Python (one package, a console script per unit) |
| `tobii/` | the Tobii Eye Tracker 5 stack — 8 interdependent derivations |

`tobii/` earns its own folder by being a *set*: `opentrack-sc` consumes
`tobii-stream-engine` and `npclient-shm-dll`, so they are wired together in
`hosts/beast/tobii-native.nix` rather than each standing alone.

If a new package doesn't clearly belong to one of these, `services/` is the
catch-all — but prefer adding a folder over stretching that one.

## The two ways a package reaches its consumer

**`callPackage` — one consumer.** The default. The service module says
`pkgs.callPackage ../pkgs/<domain>/<name>.nix { }` at its single use site. Nothing is
added to any host's `pkgs`.

**Overlay — two or more consumers.** `pkgs/overlay.nix` exposes the package as
`pkgs.<name>`, so every consumer resolves the same store path from one
evaluation. Applied by `hosts/rpi5/overlays.nix`, `hosts/beast/overlays.nix` and the
`homeConfigurations` in `flake.nix`, all via `outputs.overlays.nic-os`.

Move a package from the first form to the second the moment a second consumer
appears — that, not "is it important", is the rule. `mtg-mcp` was `callPackage`d
independently from two places (Hermes and the `claude-mtg` CLI), which evaluated
it twice with no single source of truth; it is an overlay entry now.

## Platforms

The domain folders say nothing about which host builds a package, and there is
no per-system split: entries are lazy, so a package no host references costs
nothing. Several are single-platform in practice — `tobii/*`, `rgb/*` and
`desktop/graillon-free` are BeAsT (x86) only; `services/showmycards` and
`services/ble-scale-sync` are built on the rpi5 (aarch64). Where upstream
declares it, that constraint is in the derivation's `meta.platforms`.

## Fixed-output names

**Every `fetchFromGitHub` / `fetchzip` / `fetchurl` here passes an explicit
`name` containing the version.** Not cosmetic — it is what makes a wrong hash
fail.

A fixed-output derivation's store path is keyed on `(outputHash, name)` and
nothing else. `fetchFromGitHub` and `fetchzip` default `name` to the constant
string `"source"`, so two different `rev`s with the same stale `hash` resolve to
the *same* path. If that path is already in the store, Nix never fetches: the
build succeeds and ships the old tree. `sure-0.7.3` ran as v0.7.2 for a day
exactly this way.

`fetchurl` inherits the URL's basename instead, which is safe *when the basename
carries the version* — `tobii-stream-engine-4.24.0-linux-x86_64.tar.gz` is fine
and needs no `name`. `mtg-mcp_Linux_arm64.tar.gz` is not, and does.

So:

```nix
src = fetchFromGitHub {
  name = "${pname}-${version}-source";   # ← without this, a stale hash is silent
  owner = "…";
  rev = "v${version}";
  hash = "sha256-…";
};
```

This matters most for the packages Renovate touches. Renovate rewrites `version`
(and `rev` with it) but cannot recompute a Nix fixed-output hash, so every such
PR arrives with a stale `hash` beside a new `rev` — the exact input that used to
go silent. `npmDepsHash` and `vendorHash` were always safe here: their
derivation names already embed `pname-version`, which is why those failed loudly
while `src` did not.

Sources that come from a `flake = false` input (`rtk`, `gogcli`, `goplaces`,
`showmycards`) need none of this — `flake.lock` pins them by `narHash`, so there
is no hash for a bump to leave behind.

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

The nixos-raspberrypi bootloader chain in `hosts/rpi5/configuration.nix` — five
derivations that patch an *input flake's* source. It is the largest inline build
left and the one most likely to brick a boot if botched, so it is deliberately a
separate decision.
