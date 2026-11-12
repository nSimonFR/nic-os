# no-renovate: the version is the hermes-agent flake input; fetchpatch pins a fixed commit.
# Hermes Agent (NousResearch/hermes-agent), its lean `messaging` variant — the
# rpi5 Telegram agent run by hosts/rpi5/agents/hermes/hermes.nix.
#
# Built by upstream's own flake (`hermes-agent` input), not by a derivation
# here: the version is that input's tag in flake.nix, which Renovate bumps.
{
  lib,
  hermes-agent,
  hermesPkgs,
}:
let
  # v0.22.5's pinned node segfaults on aarch64 (exit 139 building hermes-tui):
  # nixpkgs' patchelf 0.19.2 corrupts it (NixOS/patchelf#674). Rebuild the pm
  # pins with upstream's fix (hermes-agent 5a5aa9a3a, after v0.22.5); drop this
  # once the tag carries it.
  patchelfFixed = hermesPkgs.patchelf.overrideAttrs (old: {
    patches = (old.patches or [ ]) ++ [
      (hermesPkgs.fetchpatch {
        name = "patchelf-fix-executable-header-load-overlap.patch";
        url = "https://github.com/NixOS/patchelf/commit/59acc3d98b4961cfddf02090d9426ac735603218.patch";
        includes = [ "src/*" ];
        hash = "sha256-rQWWZlCa4IRrcPcxMD2xrTTD4nLOsWfdZLOk9UoIOIs=";
      })
    ];
  });
  pmPackages =
    lib.mapAttrs
      (
        _: drv:
        drv.overrideAttrs (old: {
          nativeBuildInputs = [ patchelfFixed ] ++ (old.nativeBuildInputs or [ ]);
        })
      )
      (
        lib.filterAttrs (_: lib.isDerivation) (
          hermesPkgs.callPackage "${hermes-agent}/nix/pm-packages.nix" { }
        )
      );
in
hermes-agent.packages.${hermesPkgs.stdenv.hostPlatform.system}.messaging.override {
  inherit pmPackages;
}
