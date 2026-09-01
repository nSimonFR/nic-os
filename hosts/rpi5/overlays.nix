# NixOS module: nixpkgs overlays for the RPi5 system.
{ inputs, outputs, ... }:
{
  nixpkgs.overlays = [
    # uv 0.9.26 from release-25.11 fails to build on aarch64-linux; use nixpkgs-unstable
    (
      final: prev:
      rec {
        unstablePkgs = import inputs.nixpkgs-unstable {
          system = prev.stdenv.hostPlatform.system;
          config.allowUnfree = true;
        };
        # Home Assistant's own tree — see the nixpkgs-hass comment in flake.nix.
        # It is deliberately NOT unstablePkgs: HA's on-disk .storage migration is
        # irreversible, so its pin must only ever ratchet forward, which a shared
        # input cannot promise.
        hassPkgs = import inputs.nixpkgs-hass {
          system = prev.stdenv.hostPlatform.system;
          config.allowUnfree = true;
        };
        uv = unstablePkgs.uv;
        tailscale = unstablePkgs.tailscale;
        # Vaultwarden 1.35.5+ adds AccountKeys to API key login response,
        # required for Bitwarden CLI 2026.x compatibility (vaultwarden#6912).
        vaultwarden = unstablePkgs.vaultwarden;
        # nixpkgs 25.11 ships HA 2025.11.x; HA refuses to start if the data dir
        # was written by a newer release (no downgrade allowed) — so HA rides
        # nixpkgs-hass, a pin that only moves forward, rather than the shared
        # unstable one that a routine lock bump can walk backwards.
        home-assistant = hassPkgs.home-assistant.overrideAttrs (_: {
          doInstallCheck = false;
        });
        # Must come from the same tree as home-assistant above: custom components
        # are loaded into the HA binary's own interpreter, so a split would build
        # them against a different Python ABI.
        buildHomeAssistantComponent = hassPkgs.buildHomeAssistantComponent;
        # papra: needs 26.6.0+ for AI auto-tagging; unstable pin is kept ≥ that.
        papra = unstablePkgs.papra;
        # searxng: 25.11 ships the 2026-02-22 snapshot, whose google engine still
        # hits the `asearch=arc` endpoint with a Google-Search-App User-Agent —
        # which Google now answers 403 to, so the engine could not be enabled at
        # all. Upstream dropped both in March/July (a563127a, fd5eb84a); the
        # unstable snapshot (2026-07-26) has them and issues a plain /search with
        # the ordinary Firefox UA, which this box gets a 200 for.
        searxng = unstablePkgs.searxng;
      }
    )

    # nixos-raspberrypi's page-size-16k.nix overrides jemalloc to --with-lg-page=14
    # (matching the RPi5's 16KB kernel pages). But nixpkgs already defaults to lg-page=16
    # for aarch64, and 16 >= 14, so the cached version works fine. Undo the override so
    # jemalloc-dependent packages (ruff, litellm, etc.) hit cache.nixos.org instead of
    # rebuilding from source.
    (final: prev: {
      jemalloc = prev.jemalloc.overrideAttrs (old: {
        configureFlags = builtins.map
          (f: if builtins.match ".*--with-lg-page=.*" f != null then "--with-lg-page=16" else f)
          old.configureFlags;
      });
    })

    # Redis/Valkey cluster tests are flaky in the Nix sandbox
    (final: prev: {
      redis = prev.redis.overrideAttrs (_: {
        doCheck = false;
        doInstallCheck = false;
      });
      valkey = prev.valkey.overrideAttrs (_: {
        doCheck = false;
        doInstallCheck = false;
      });
    })

    # beszel 0.18.7 ships a CPU-percent test that assumes single-CPU
    # semantics (asserts pct <= 100) but the rpi5 has 4 cores so the
    # subsequent-call delta can briefly exceed 100%. Skip checks.
    (final: prev: {
      beszel = prev.beszel.overrideAttrs (_: {
        doCheck = false;
        doInstallCheck = false;
      });
    })

    # This repo's own packages — `pkgs.rtk`, `pkgs.showmycards`, `pkgs.mtg-mcp`.
    # Defined once in pkgs/overlay.nix (exposed as outputs.overlays.nic-os) and
    # reused here so NixOS modules (cyrus, showmycards, hermes) and the
    # NixOS-integrated home-manager generation resolve the same packages as the
    # standalone HM configs.
    outputs.overlays.nic-os
  ];
}
