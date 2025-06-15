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