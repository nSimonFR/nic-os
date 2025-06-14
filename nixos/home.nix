{ config, pkgs, inputs, ... }:
{
  home.username = "nsimon";
  home.homeDirectory = "/home/nsimon";
  home.stateVersion = "25.05";

  home.packages = with pkgs; [
    git
    kitty
  ];

  wayland.windowManager.hyprland = {
    enable = true;
    extraConfig = builtins.readFile ./hyprland.conf;
  };

  programs.home-manager.enable = true;
}
