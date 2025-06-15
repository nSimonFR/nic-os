{ config, pkgs, ... }:
{
  home.packages = with pkgs; [
    # TODO sort A-Z
    dconf
    lxqt.lxqt-policykit
    rofi
    cliphist
    code-cursor
    dunst
    pipewire
    pavucontrol
    wireplumber
    eww
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
} 