# NixOS module: nixpkgs overlays for the RPi5 system.
{ inputs, ... }:
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
        # nixpkgs 25.11 ships HA 2025.11.x; HA refuses to start if .HA_VERSION
        # in the data dir is newer than the binary (no downgrade allowed).
        # Track unstable so the package version always meets or exceeds what was
        # last written by the previous release.
        home-assistant = unstablePkgs.home-assistant.overrideAttrs (_: {
          doInstallCheck = false;
        });
        buildHomeAssistantComponent = unstablePkgs.buildHomeAssistantComponent;
      }
    )

    inputs.nix-openclaw.overlays.default

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
  ];
}
