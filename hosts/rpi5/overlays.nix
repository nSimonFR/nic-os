# NixOS module: nixpkgs overlays for the RPi5 system.
{ inputs, outputs, ... }:
{
  nixpkgs.overlays = [
    # uv 0.9.26 from release-25.11 fails to build on aarch64-linux; use nixpkgs-unstable
    (_final: prev: rec {
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
      inherit (unstablePkgs) uv;
      inherit (unstablePkgs) tailscale;
      # no-renovate: temporary bump until the nixpkgs-unstable pin carries >= 2026.10.3.
      # T3 Connect's relay refuses cloudflared older than 2026.10.3 since T3 0.1.11
      # ("T3CODE_CLOUDFLARED_PATH must point to cloudflared 2026.10.3 or newer"), and
      # then the apps see the rpi5 as unreachable. T3 is its only user.
      # release-26.05 has 2026.5.2 and the unstable pin 2026.10.1, so bump
      # unstable's (its Go toolchain is new enough). Drop once the pin has it.
      cloudflared = unstablePkgs.cloudflared.overrideAttrs (_: rec {
        version = "2026.10.7";
        src = prev.fetchFromGitHub {
          owner = "cloudflare";
          repo = "cloudflared";
          tag = version;
          hash = "sha256-qyGcPCYaa4UT8ws5sUW+SXCp8QWbVniB4QFR8gGE0ds=";
        };
        vendorHash = "sha256-ah+kI+bWIZqsi9U+AJtWME9rfjTr6QpiLQy0RXNlDzc=";
        ldflags = [
          "-s"
          "-w"
          "-X main.Version=${version}"
          "-X github.com/cloudflare/cloudflared/cmd/cloudflared/updater.BuiltForPackageManager=nixpkgs"
        ];
      });
      # Vaultwarden 1.35.5+ adds AccountKeys to API key login response,
      # required for Bitwarden CLI 2026.x compatibility (vaultwarden#6912).
      inherit (unstablePkgs) vaultwarden;
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
      inherit (hassPkgs) buildHomeAssistantComponent;
      # papra: needs 26.6.0+ for AI auto-tagging; unstable pin is kept ≥ that.
      inherit (unstablePkgs) papra;
      # searxng: 25.11 ships the 2026-02-22 snapshot, whose google engine still
      # hits the `asearch=arc` endpoint with a Google-Search-App User-Agent —
      # which Google now answers 403 to, so the engine could not be enabled at
      # all. Upstream dropped both in March/July (a563127a, fd5eb84a); the
      # unstable snapshot (2026-07-26) has them and issues a plain /search with
      # the ordinary Firefox UA, which this box gets a 200 for.
      inherit (unstablePkgs) searxng;
    })

    # nixos-raspberrypi's page-size-16k.nix overrides jemalloc to --with-lg-page=14
    # (matching the RPi5's 16KB kernel pages). But nixpkgs already defaults to lg-page=16
    # for aarch64, and 16 >= 14, so the cached version works fine. Undo the override so
    # jemalloc-dependent packages (ruff, litellm, etc.) hit cache.nixos.org instead of
    # rebuilding from source.
    (_final: prev: {
      jemalloc = prev.jemalloc.overrideAttrs (old: {
        configureFlags = builtins.map (
          f: if builtins.match ".*--with-lg-page=.*" f != null then "--with-lg-page=16" else f
        ) old.configureFlags;
      });
    })

    # no-renovate: temporary CVE backport (libraw below).
    # libraw 0.22.1 (26.05) carries CVE-2026-20884/20911/21413/24450; 0.22.2
    # fixes them. Same tree's build recipe, newer tag. Drop once 26.05 ships it.
    (_final: prev: {
      libraw = prev.libraw.overrideAttrs (_: {
        version = "0.22.2";
        src = prev.fetchFromGitHub {
          owner = "LibRaw";
          repo = "LibRaw";
          tag = "0.22.2";
          hash = "sha256-mtDQ3NaHB1ogl61SI0KlKjWlOsNVxeAKal+7YanXJ+s=";
        };
      });
    })

    # Redis/Valkey cluster tests are flaky in the Nix sandbox
    (_final: prev: {
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
    (_final: prev: {
      beszel = prev.beszel.overrideAttrs (_: {
        doCheck = false;
        doInstallCheck = false;
      });
    })

    # This repo's packages — `pkgs.rtk` and `pkgs.showmycards`.
    # Defined once in pkgs/overlay.nix (exposed as outputs.overlays.nic-os) and
    # reused here so NixOS modules (cyrus, showmycards, hermes) and the
    # NixOS-integrated home-manager generation resolve the same packages as the
    # standalone HM configs.
    outputs.overlays.nic-os
  ];
}
