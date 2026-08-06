# NixOS module: nixpkgs overlays for the BeAsT system.
# Mirrors rpi5/overlays.nix.
{ outputs, ... }:
{
  nixpkgs.overlays = [
    # This repo's own packages — `pkgs.openrgb-lg` here. Defined once in
    # pkgs/overlay.nix (exposed as outputs.overlays.nic-os) so the RGB module
    # and services.hardware.openrgb.package resolve the same derivation.
    # Previously an anonymous overlay declared inside nixos/rgb/openrgb-lg.nix.
    outputs.overlays.nic-os
  ];
}
