{
  inputs,
  lib,
  config,
  pkgs,
  ...
}: {
  imports = [
    ./programs.nix
  ];

  home.stateVersion = "23.05";
  nixpkgs = {
    config = {
      allowUnfree = true;
      allowUnfreePredicate = _: true;
    };
  };
}
