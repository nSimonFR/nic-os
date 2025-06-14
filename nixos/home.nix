{ config, pkgs, inputs, ... }:
{
  home = {
    # TODO use var
    username = "nsimon";
    homeDirectory = "/home/nsimon";

    packages = with pkgs; [
      # TODO sort A-Z
      kitty
      _1password-gui
      docker
      slack
      spotify
      (discord.override {
        withOpenASAR = true;
        withVencord = true;
      })
      (writeShellScriptBin "discord-fixed" ''
        exec ${discord}/bin/discord --enable-features=UseOzonePlatform --ozone-platform=wayland
      '')
    ];
  };

  wayland.windowManager.hyprland = {
    enable = true;
    extraConfig = builtins.readFile ./hyprland.conf;
  };
}
