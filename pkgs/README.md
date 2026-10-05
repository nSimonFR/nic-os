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

Every fetcher here passes an explicit `name` containing the version, because an
FOD's store path is keyed on `(outputHash, name)` and `fetchFromGitHub` defaults
that name to the constant `"source"` — so a bumped `rev` beside a stale `hash`
silently reuses the old tree rather than failing. `sure-0.7.3` ran as v0.7.2 for
a day exactly this way.

```nix
src = fetchFromGitHub {
  name = "${pname}-${version}-source";   # ← without this, a stale hash is silent
  owner = "…";
  rev = "v${version}";
  hash = "sha256-…";
};
```

Renovate rewrites `version` on `pkgs/` packages but cannot recompute the hash, so
every such PR arrives with a new `rev` beside a stale `hash`.

### What counts as version-bearing

- `"${pname}-${version}-source"` — the default; use it unless something prevents it.
- A literal version, where no `version` attr is in scope: `"xplane-sdk-411-source"`,
  `"openrgb-${version}-source"` after hoisting `version` into a `let`.
- For a plain file, keep the extension: `"${pname}-${version}.pkg.tar.zst"`.

`fetchurl` names itself after the URL's basename, which *often* carries the
version — don't rely on that. Name it explicitly like everything else.

### When adding `name` to an existing fetcher

Renaming a fixed-output derivation changes its store path, which forces a
re-fetch and re-verifies the declared hash against upstream. **Verify before you
commit**, or a hash that is already stale turns into a build failure someone else
has to diagnose:

```sh
# unpacked (fetchFromGitHub / fetchFromGitLab / fetchzip)
nix-prefetch-url --unpack "https://github.com/<owner>/<repo>/archive/<rev>.tar.gz"
nix hash to-sri --type sha256 <base32-from-above>

# flat file (fetchurl)
nix store prefetch-file --hash-type sha256 "<url>"
```

### Exceptions

A source that comes from a `flake = false` input (`rtk`, `gogcli`, `goplaces`,
`showmycards`) needs none of this — `flake.lock` pins it by `narHash`, so there
is no fetcher call and no hash for a bump to leave behind.

An upstream that genuinely has no versions (a file tracked off `master`, like the
Forgejo theme in `hosts/rpi5/forgejo.nix`) cannot satisfy the rule. Say so in a
comment on the fetcher rather than leaving it looking like an oversight.

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
