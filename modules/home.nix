{
  inputs,
  lib,
  config,
  pkgs,
  ...
}: {
  imports = [
    ./common.nix
  ];

  nixpkgs = {
    config = {
      allowUnfree = true;
      allowUnfreePredicate = _: true;
    };
  };

  home = {
    stateVersion = "23.05";
    username = "nsimon";
    homeDirectory = "/home/nsimon";
  };

  systemd.user.startServices = "sd-switch";
  programs.home-manager.enable = true;
}
