{ config, pkgs, ... }:
{
  home.packages = with pkgs; [
    _1password-gui
    cliphist
    code-cursor
    dconf
    (discord.override {
      withOpenASAR = true;
      withVencord = true;
    })
    (writeShellScriptBin "discord-fixed" ''
      exec ${discord}/bin/discord --enable-features=UseOzonePlatform --ozone-platform=wayland
    '')
    docker
    dunst
    eww
    kitty
    lxqt.lxqt-policykit
    pavucontrol
    pipewire
    rofi
    slack
    spotify
    wireplumber
  ];
} 