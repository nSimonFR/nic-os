{ pkgs, ... }:

{
  # `pkgs.openrgb-lg` comes from the repo overlay (pkgs/overlay.nix, applied in
  # hosts/beast/overlays.nix) — hosts/beast/configuration.nix wires the same package into
  # services.hardware.openrgb.package.
  environment.systemPackages = with pkgs; [
    openrgb-lg
  ];
}
