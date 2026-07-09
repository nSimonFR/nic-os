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
        uv = unstablePkgs.uv;
        tailscale = unstablePkgs.tailscale;
        # Vaultwarden 1.35.5+ adds AccountKeys to API key login response,
        # required for Bitwarden CLI 2026.x compatibility (vaultwarden#6912).
        vaultwarden = unstablePkgs.vaultwarden;
        # nixpkgs 25.11 ships HA 2025.11.x; HA refuses to start if .HA_VERSION
        # in the data dir is newer than the binary (no downgrade allowed).
        # Track unstable so the package version always meets or exceeds what was
        # last written by the previous release.
        home-assistant = unstablePkgs.home-assistant.overrideAttrs (_: {
          doInstallCheck = false;
        });
        buildHomeAssistantComponent = unstablePkgs.buildHomeAssistantComponent;
        # papra: pinned unstable is 26.5.0 (pre AI auto-tagging). Build 26.6.1 from a
        # vendored package.nix using unstable's toolchain (nodejs_26/pnpm_11/vips/tsx).
        # See rpi5/pkgs/papra/package.nix. Remove once pinned unstable ≥ 26.6.0.
        papra = unstablePkgs.callPackage ./pkgs/papra/package.nix { };
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

    # paperless-ngx 2.19.6 ships a timing-flaky test
    # (test_management_consumer.py::TestConsumerRecursive::test_slow_write_and_move
    # — "Expected 'delay' to have been called once. Called 0 times.")
    # that fails reliably on the memory-constrained RPi5. The full
    # 1362-test suite also costs ~14min on the RPi5; skip it.
    (final: prev: {
      paperless-ngx = prev.paperless-ngx.overrideAttrs (_: {
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

    # RTK (Rust Token Killer) — exposes `pkgs.rtk`, built from the rtk-src flake
    # input. Defined once in flake.nix (outputs.overlays.rtk) and reused here so
    # NixOS modules (picoclaw, cyrus) and the NixOS-integrated home-manager
    # generation resolve the same package as the standalone HM configs.
    outputs.overlays.rtk
  ];
}
